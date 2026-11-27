defmodule URP.Connection do
  @moduledoc false

  # A connection to soffice, and the process that owns it.
  #
  # soffice cannot be interrupted. It finishes every call it was sent, and keeps
  # what the call made — a loaded document, a temp file — until it is told to
  # let go. So the connection runs each job to the end in its own process,
  # whether or not anyone is still waiting for the result, and a job releases
  # what it opened in `after` blocks. The same holds at shutdown: the process
  # traps exits and stops once the job in hand is done.
  #
  # The process is either disconnected, trying to connect with a growing delay
  # between attempts, or connected, in which case it asks its pool's queue for
  # a job, runs it, answers the caller and asks again. A socket failure sends
  # it back to connecting.
  #
  # Inside a job, `call/6` makes a UNO call and returns its result. It raises
  # `URP.Error` when soffice answers with an exception, which leaves the
  # connection good, and `URP.SocketError` when the socket gives out.

  @behaviour :gen_statem

  alias URP.Protocol, as: P
  alias URP.Queue

  require Logger

  @type t :: %__MODULE__{
          sock: :gen_tcp.socket(),
          tid: binary(),
          context: String.t() | nil,
          service_manager: String.t() | nil,
          desktop: String.t() | nil,
          file_access: String.t() | nil,
          silence: timeout(),
          deadline: timeout(),
          chunk_size: pos_integer()
        }

  defstruct [
    :sock,
    :tid,
    :context,
    :service_manager,
    :desktop,
    :file_access,
    :silence,
    :chunk_size,
    deadline: :infinity
  ]

  @interface "com.sun.star.uno.XInterface"

  @defaults [
    host: "localhost",
    port: 2002,
    index: 0,
    connect_timeout: 5_000,
    send_timeout: 120_000,
    drain_timeout: 300_000,
    chunk_size: 1024 * 1024,
    backoff_initial: 500,
    backoff_max: 5_000
  ]

  # How long a job in hand gets to finish when the pool shuts down.
  @shutdown 30_000

  # What changes while a job runs and must survive a raise half way through
  # it: what soffice has cached, the interfaces objects are known by, and the
  # first socket failure. Hence the process dictionary, not the job's arguments.
  defp state, do: Process.get(__MODULE__)
  defp update(fun), do: Process.put(__MODULE__, fun.(state()))

  @doc """
  Start a connection that takes its jobs from `:queue`.

  Options: `:host`, `:port`, `:index` (which of the addresses `:host` resolves
  to this connection takes), `:connect_timeout`, `:send_timeout`,
  `:drain_timeout`, `:chunk_size`, `:backoff_initial` and `:backoff_max`.
  """
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts), do: :gen_statem.start_link(__MODULE__, opts, [])

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: @shutdown}
  end

  ## Inside a job

  @doc """
  Call a method on a remote object and return what it returns.

  `function` is the method's position in `interface`. `args` are `{type, value}`
  pairs and `returns` a type, or a list of them for a method with out
  parameters; see `URP.Protocol` for both.
  """
  @spec call(t(), String.t(), String.t(), byte(), [{P.type(), term()}], returns) :: term()
        when returns: P.type() | [P.type()]
  def call(conn, oid, interface, function, args, returns) do
    query_interface(conn, oid, interface)
    conn |> invoke(oid, interface, function, args) |> read(returns) |> known(returns)
  end

  # soffice can be called on an object through an interface once it has
  # handed the object over as that interface, which a method returning one
  # does. Only a different interface has to be asked for.
  defp known(oid, {:interface, interface}) when is_binary(oid) do
    update(&%{&1 | queried: MapSet.put(&1.queried, {oid, interface})})
    oid
  end

  defp known(value, _returns), do: value

  @doc """
  Tell soffice we are done with an object it handed us, so that it can let go
  of it. There is no reply to wait for.
  """
  @spec release(t(), String.t()) :: :ok
  def release(conn, oid) do
    # Alone among requests, a release carries no current context.
    P.send_frame(conn.sock, P.header(2, @interface, oid, conn.tid))
  end

  @doc """
  Stop the job here if its caller has stopped waiting for it.

  For the points between the steps of a job, where going on would be work
  nobody wants. What the job has opened so far is released as it unwinds.
  """
  @spec checkpoint(t()) :: :ok
  def checkpoint(conn) do
    if Queue.expired?(conn.deadline), do: throw(:abandoned), else: :ok
  end

  ## States

  @impl :gen_statem
  def callback_mode, do: :state_functions

  @impl :gen_statem
  def init(opts) do
    Process.flag(:trap_exit, true)

    data =
      @defaults
      |> Keyword.merge(opts)
      |> Map.new()
      |> Map.merge(%{address: nil, conn: nil, holding: false})

    {:ok, :disconnected, data, {:next_event, :internal, {:connect, 1}}}
  end

  @doc false
  def disconnected(type, {:connect, attempt}, data) when type in [:internal, :state_timeout] do
    address = address(data.host, data.index)

    case connect(address, data) do
      # A job already in hand is run before another is asked for.
      {:ok, conn} ->
        ready = if data.holding, do: [], else: [{:next_event, :internal, :ready}]
        {:next_state, :connected, %{data | conn: conn, address: address, holding: false}, ready}

      {:error, reason} ->
        delay = min(data.backoff_initial * Integer.pow(2, min(attempt - 1, 30)), data.backoff_max)
        meta = %{host: data.host, address: address, port: data.port, reason: reason}
        :telemetry.execute([:urp, :connection, :retry], %{attempt: attempt, delay: delay}, meta)

        Logger.warning(
          "URP connection failed (attempt #{attempt}, retry in #{delay}ms): #{reason}",
          Map.to_list(Map.delete(meta, :reason))
        )

        {:keep_state_and_data, {:state_timeout, delay, {:connect, attempt + 1}}}
    end
  end

  # A job that found its socket dead waits here for the new one.
  def disconnected(:info, {:job, _from, _job}, _data), do: {:keep_state_and_data, :postpone}
  def disconnected(:info, _message, _data), do: :keep_state_and_data

  @doc false
  def connected(:internal, :ready, data) do
    Queue.ready(data.queue)
    :keep_state_and_data
  end

  def connected(:info, {:job, from, job}, data) do
    cond do
      Queue.expired?(job.deadline) ->
        {:keep_state_and_data, {:next_event, :internal, :ready}}

      # A passive socket does not say when the other end has gone, which after
      # a soffice restart is every idle connection. Asking it for nothing tells.
      :gen_tcp.recv(data.conn.sock, 0, 0) != {:error, :timeout} ->
        reconnect(%{data | holding: true}, :postpone)

      true ->
        started = System.monotonic_time()
        silence = max(job.timeout, data.drain_timeout)
        update(&%{&1 | queried: &1.bootstrapped})

        {fate, result} =
          attempt(fn -> job.fun.(%{data.conn | silence: silence, deadline: job.deadline}) end)

        GenServer.reply(from, {result, started})
        if Queue.expired?(job.deadline), do: report_drain(data, job.deadline, fate, result)

        case fate do
          :keep -> {:keep_state_and_data, {:next_event, :internal, :ready}}
          :drop -> reconnect(data, [])
        end
    end
  end

  def connected(:info, _message, _data), do: :keep_state_and_data

  defp reconnect(data, actions) do
    :gen_tcp.close(data.conn.sock)

    {:next_state, :disconnected, %{data | conn: nil},
     [{:next_event, :internal, {:connect, 1}} | List.wrap(actions)]}
  end

  # The i-th connection of a pool takes the i-th address its host resolves to,
  # so a pool behind a round-robin name reaches every soffice behind it.
  @doc false
  @spec address(String.t(), non_neg_integer()) :: String.t()
  def address(host, index) do
    case :inet.getaddrs(String.to_charlist(host), :inet) do
      {:ok, addresses} ->
        addresses = addresses |> Enum.uniq() |> Enum.sort()
        addresses |> Enum.at(rem(index, length(addresses))) |> :inet.ntoa() |> List.to_string()

      {:error, _reason} ->
        host
    end
  end

  defp connect(address, data) do
    Process.put(__MODULE__, %{
      reader: P.reader(),
      queried: MapSet.new(),
      bootstrapped: MapSet.new(),
      failure: nil
    })

    socket_opts = [
      :binary,
      active: false,
      send_timeout: data.send_timeout,
      send_timeout_close: true
    ]

    case :gen_tcp.connect(
           String.to_charlist(address),
           data.port,
           socket_opts,
           data.connect_timeout
         ) do
      {:ok, sock} ->
        conn = %__MODULE__{
          sock: sock,
          tid: :crypto.strong_rand_bytes(20),
          silence: data.connect_timeout,
          chunk_size: data.chunk_size
        }

        case attempt(fn -> bootstrap(conn) end) do
          {:keep, {:ok, conn}} ->
            {:ok, conn}

          {_fate, {:error, reason}} ->
            :gen_tcp.close(sock)
            {:error, "handshake failed: #{describe(reason)}"}
        end

      {:error, reason} ->
        {:error, "connection failed: #{describe(reason)}"}
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: Exception.message(URP.SocketError.exception(reason: reason))

  ## Jobs

  # What a job comes to, and whether the connection is still in step with
  # soffice afterwards. Anything unforeseen leaves that unknown.
  defp attempt(fun) do
    {:keep, {:ok, fun.()}}
  rescue
    e in URP.Error -> {:keep, {:error, e.message}}
    e in URP.SocketError -> {:drop, {:error, state().failure || e.reason}}
  catch
    :throw, :abandoned ->
      {:keep, {:error, :timeout}}

    kind, reason ->
      Logger.error(Exception.format(kind, reason, __STACKTRACE__))
      {:drop, {:error, :protocol_error}}
  end

  defp report_drain(data, deadline, fate, result) do
    outcome = if fate == :keep, do: :ok, else: result
    overrun = System.monotonic_time(:millisecond) - deadline

    :telemetry.execute(
      [:urp, :connection, :drain],
      %{duration: System.convert_time_unit(overrun, :millisecond, :native)},
      %{host: data.host, address: data.address, port: data.port, result: outcome}
    )
  end

  ## Calls

  defp query_interface(_conn, _oid, @interface), do: :ok

  defp query_interface(conn, oid, interface) do
    if not MapSet.member?(state().queried, {oid, interface}) do
      if conn |> invoke(oid, @interface, 0, type: interface) |> read(:any) == nil do
        raise URP.Error, "queryInterface returned void for #{interface}"
      end

      update(&%{&1 | queried: MapSet.put(&1.queried, {oid, interface})})
    end

    :ok
  end

  # Once the socket has failed nothing more can be asked of soffice. Closing
  # it makes what the job still tries on its way out fail at once, rather than
  # wait out the silence again, and the first failure is the one reported.
  defp invoke(conn, oid, interface, function, args) do
    P.send_frame(conn.sock, P.request(function, interface, oid, conn.tid, args))
    await_reply(conn)
  rescue
    e in URP.SocketError ->
      :gen_tcp.close(conn.sock)
      update(&%{&1 | failure: &1.failure || e.reason})
      reraise e, __STACKTRACE__
  end

  # A reply is exactly the values its method returns: anything left over means
  # the method's signature in `URP.UNO` is wrong.
  defp read(body, returns) when is_list(returns) do
    {values, <<>>} =
      Enum.map_reduce(returns, body, fn type, rest ->
        {value, rest, reader} = P.decode(type, rest, state().reader)
        update(&%{&1 | reader: reader})
        {value, rest}
      end)

    values
  end

  defp read(body, returns), do: body |> read([returns]) |> hd()

  # soffice holds no object of ours, so after the handshake the only thing it
  # can send besides a reply is `release`, for a reference of its own that it
  # was handed back. That is one-way and needs no answer.
  defp await_reply(conn) do
    case recv_message(conn) do
      {:reply, body} -> body
      {:exception, message} -> raise URP.Error, message
      {:request, 2} -> await_reply(conn)
    end
  end

  defp recv_message(conn) do
    {message, reader} =
      conn.sock |> P.recv_frame(conn.silence) |> P.decode_message(state().reader)

    update(&%{&1 | reader: reader})
    message
  end

  ## Handshake and bootstrap

  # The context comes first: the service manager is asked for it, which is
  # what teaches soffice that we know the context as an XComponentContext and
  # lets us hand it back when creating the rest.
  defp bootstrap(conn) do
    handshake(conn)

    context =
      conn |> invoke("StarOffice.ComponentContext", @interface, 0, type: @interface) |> read(:any)

    conn = %{conn | context: context}
    conn = %{conn | service_manager: URP.UNO.call(conn, context, :get_service_manager)}
    conn = %{conn | desktop: URP.UNO.create_instance(conn, "com.sun.star.frame.Desktop")}

    conn = %{
      conn
      | file_access: URP.UNO.create_instance(conn, "com.sun.star.ucb.SimpleFileAccess")
    }

    # These two live as long as the connection, so they are asked once here
    # for the interfaces every conversion calls them through. What a job
    # learns about its own objects is forgotten when it ends.
    query_interface(conn, conn.desktop, "com.sun.star.frame.XComponentLoader")
    query_interface(conn, conn.file_access, "com.sun.star.ucb.XSimpleFileAccess")
    update(&%{&1 | bootstrapped: &1.queried})
    conn
  end

  # Both sides open by asking to change the protocol properties (function 4),
  # each with a nonce, and the higher nonce wins. Ours is the lowest there is,
  # so soffice wins, is told so, and commits its properties (function 5). The
  # replies carry no thread id: soffice reads them as answering its last call.
  defp handshake(conn) do
    {:request, 4} = recv_message(conn)

    P.send_frame(conn.sock, [
      P.header(
        4,
        "com.sun.star.bridge.XProtocolProperties",
        "UrpProtocolProperties",
        ".UrpProtocolPropertiesTid"
      ),
      <<-2_147_483_648::32-signed>>
    ])

    {:reply, <<0::32>>} = recv_message(conn)
    P.send_frame(conn.sock, <<0x80, 1::32-signed>>)
    {:request, 5} = recv_message(conn)
    P.send_frame(conn.sock, <<0x80>>)
  end
end
