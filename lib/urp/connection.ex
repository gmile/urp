defmodule URP.Connection do
  @moduledoc """
  Supervised GenServer for serialized document conversion.

  Wraps `URP.Bridge` calls in a GenServer so that only one conversion runs
  at a time. Concurrent callers queue in the GenServer mailbox and get a
  timeout exit if they wait too long.

  soffice is single-threaded — without serialization, concurrent callers
  all open TCP connections that soffice processes one at a time, with no
  backpressure or visibility into the queue.

  ## Setup

      # In your application supervision tree
      children = [
        {URP.Connection, host: "soffice", port: 2002}
      ]

  ## Usage

      {:ok, pdf} = URP.Connection.convert_stream(bytes)
      {:ok, pdf} = URP.Connection.convert_stream(MyConn, bytes, filter: "calc_pdf_Export")

  ## Direct vs supervised

  For scripts, IEx, and tests, use `URP` directly — no GenServer needed.
  For production web apps, use `URP.Connection` for serialization and
  backpressure.
  """

  use GenServer

  alias URP.Bridge

  @default_timeout 120_000

  @doc """
  Start a connection process.

  ## Options

    * `:name` — process name (default `URP.Connection`)
    * `:host` — soffice hostname (default `"localhost"`)
    * `:port` — soffice URP listener port (default `2002`)
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Map.new(opts), name: name)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  Convert document bytes to PDF via streaming.

  ## Options

    * `:filter`  — export filter name (default `"writer_pdf_Export"`)
    * `:sink`    — output destination: `{:path, path}` or `fun/1` (default: in-memory)
    * `:timeout` — call timeout in ms (default `#{@default_timeout}`)
  """
  def convert_stream(server \\ __MODULE__, input_bytes, opts \\ [])
      when is_binary(input_bytes) do
    {timeout, opts} = Keyword.pop(opts, :timeout, @default_timeout)
    GenServer.call(server, {:convert_stream, input_bytes, opts}, timeout)
  end

  @doc """
  Convert a local file to PDF via file-backed streaming.

  Reads from the file on demand — the full file is not loaded into memory.

  ## Options

    * `:filter`  — export filter name (default `"writer_pdf_Export"`)
    * `:sink`    — output destination: `{:path, path}` or `fun/1` (default: in-memory)
    * `:timeout` — call timeout in ms (default `#{@default_timeout}`)
  """
  def convert_file_stream(server \\ __MODULE__, input_path, opts \\ [])
      when is_binary(input_path) do
    {timeout, opts} = Keyword.pop(opts, :timeout, @default_timeout)
    GenServer.call(server, {:convert_file_stream, input_path, opts}, timeout)
  end

  @doc """
  Convert a file to PDF via file:// URLs (requires shared filesystem).

  ## Options

    * `:filter`  — export filter name (default `"writer_pdf_Export"`)
    * `:timeout` — call timeout in ms (default `#{@default_timeout}`)
  """
  def convert(server \\ __MODULE__, input_path, output_path \\ nil, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout, @default_timeout)
    GenServer.call(server, {:convert, input_path, output_path, opts}, timeout)
  end

  ## Callbacks

  @impl true
  def init(config) do
    {:ok,
     %{
       host: Map.get(config, :host, "localhost"),
       port: Map.get(config, :port, 2002)
     }}
  end

  @impl true
  def handle_call({:convert_stream, bytes, opts}, _from, config) do
    store_opts = Keyword.take(opts, [:filter, :sink])

    result =
      do_stream(config, fn conn -> Bridge.load_document_stream!(conn, bytes) end, store_opts)

    {:reply, result, config}
  end

  def handle_call({:convert_file_stream, path, opts}, _from, config) do
    store_opts = Keyword.take(opts, [:filter, :sink])

    result =
      do_stream(
        config,
        fn conn -> Bridge.load_document_file_stream!(conn, path) end,
        store_opts
      )

    {:reply, result, config}
  end

  def handle_call({:convert, input_path, output_path, opts}, _from, config) do
    output_path = output_path || Path.rootname(input_path) <> ".pdf"
    filter = Keyword.get(opts, :filter, "writer_pdf_Export")
    in_url = "file://" <> Path.expand(input_path)
    out_url = "file://" <> Path.expand(output_path)

    result =
      with_connection(config, fn conn ->
        doc = Bridge.load_document!(conn, in_url)
        Bridge.store_to_url!(conn, doc, out_url, filter)
        Bridge.close_document!(conn, doc)
        {:ok, output_path}
      end)

    {:reply, result, config}
  end

  defp do_stream(config, load_fn, store_opts) do
    with_connection(config, fn conn ->
      doc = load_fn.(conn)
      result = Bridge.store_to_stream!(conn, doc, store_opts)

      case result do
        :ok -> :ok
        bytes when is_binary(bytes) -> {:ok, bytes}
      end
    end)
  end

  defp with_connection(config, fun) do
    conn = Bridge.open!(config.host, config.port)

    try do
      fun.(conn)
    rescue
      e -> {:error, Exception.message(e)}
    after
      Bridge.close!(conn)
    end
  end
end
