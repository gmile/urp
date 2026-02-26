defmodule URP do
  @moduledoc """
  Pure Elixir client for document conversion via LibreOffice's UNO Remote Protocol.

  Talks directly to a `soffice` process over TCP.
  No Python, no unoserver, no Gotenberg.

  ## Setup

  Define a converter module and add it to your supervision tree:

      defmodule MyApp.Converter do
        use URP, otp_app: :my_app
      end

      # config/runtime.exs
      config :my_app, MyApp.Converter,
        host: "soffice",
        port: 2002,
        pool_size: 4

      # application.ex
      children = [
        MyApp.Converter
      ]

  ## Usage

      {:ok, pdf_bytes} = MyApp.Converter.convert_stream(docx_bytes)
      {:ok, pdf_bytes} = MyApp.Converter.convert_file_stream("/path/to/input.docx")
      :ok = MyApp.Converter.convert_stream(docx_bytes, sink: {:path, "/tmp/out.pdf"})

  ## Testing

      URP.Test.stub(MyApp.Converter, fn _input, _opts -> {:ok, "fake"} end)
      {:ok, "fake"} = MyApp.Converter.convert_stream(docx_bytes)

  See `URP.Test` for details.
  """

  alias URP.Bridge

  @doc """
  Generates a supervised converter module backed by a connection pool.

  ## Options

    * `:otp_app` (required) — application to read config from (reads
      `Application.get_env(otp_app, __MODULE__, [])` at runtime)

  ## Config keys

    * `:host` — soffice hostname (default `"localhost"`)
    * `:port` — soffice URP listener port (default `2002`)
    * `:pool_size` — number of connections (default `4`)

  ## Generated functions

    * `child_spec/1` — for adding to a supervision tree
    * `convert_stream/2` — convert bytes to PDF
    * `convert_file_stream/2` — convert a local file to PDF
    * `convert/3` — convert via file:// URLs (requires shared filesystem)

  All functions are stubbable via `URP.Test.stub/2`.
  """
  defmacro __using__(opts) do
    quote do
      @urp_otp_app Keyword.fetch!(unquote(opts), :otp_app)

      def child_spec(override_opts \\ []) do
        runtime = Application.get_env(@urp_otp_app, __MODULE__, [])
        opts = Keyword.merge(runtime, override_opts)

        %{
          id: __MODULE__,
          start: {URP.Pool, :start_link, [Keyword.put(opts, :name, __MODULE__)]}
        }
      end

      @doc "Convert document bytes to PDF. See `URP.Pool.convert_stream/3`."
      def convert_stream(input_bytes, opts \\ []) when is_binary(input_bytes) do
        case URP.Test.__fetch_stub__(__MODULE__) do
          {:ok, fun} -> fun.(input_bytes, opts)
          :error -> URP.Pool.convert_stream(__MODULE__, input_bytes, opts)
        end
      end

      @doc "Convert a local file to PDF via streaming. See `URP.Pool.convert_file_stream/3`."
      def convert_file_stream(input_path, opts \\ []) when is_binary(input_path) do
        case URP.Test.__fetch_stub__(__MODULE__) do
          {:ok, fun} -> fun.(input_path, opts)
          :error -> URP.Pool.convert_file_stream(__MODULE__, input_path, opts)
        end
      end

      @doc "Convert a file to PDF via file:// URLs. See `URP.Pool.convert/4`."
      def convert(input_path, output_path \\ nil, opts \\ []) do
        case URP.Test.__fetch_stub__(__MODULE__) do
          {:ok, fun} -> fun.(input_path, opts)
          :error -> URP.Pool.convert(__MODULE__, input_path, output_path, opts)
        end
      end

      defoverridable child_spec: 1, convert_stream: 2, convert_file_stream: 2, convert: 3
    end
  end

  @type sink :: {:path, Path.t()} | (binary() -> any())
  @type stream_opt ::
          {:host, String.t()}
          | {:port, non_neg_integer()}
          | {:filter, String.t()}
          | {:sink, sink()}

  @doc """
  Convert a file to PDF via a running soffice instance.

  `input_path` and `output_path` must be accessible to soffice at those exact
  paths (e.g. via a shared volume mount when using Docker/Kubernetes).

  ## Options

    * `:host`   — soffice hostname (default `"localhost"`)
    * `:port`   — soffice URP listener port (default `2002`)
    * `:filter` — [export filter name](https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html) (default `"writer_pdf_Export"`)
  """
  @spec convert(Path.t(), Path.t() | nil, keyword()) :: {:ok, Path.t()}
  def convert(input_path, output_path \\ nil, opts \\ []) do
    output_path = output_path || Path.rootname(input_path) <> ".pdf"
    host = Keyword.get(opts, :host, "localhost")
    port = Keyword.get(opts, :port, 2002)
    filter = Keyword.get(opts, :filter, "writer_pdf_Export")

    in_url = "file://" <> Path.expand(input_path)
    out_url = "file://" <> Path.expand(output_path)

    conn = Bridge.open!(host, port)

    try do
      doc = Bridge.load_document!(conn, in_url)
      Bridge.store_to_url!(conn, doc, out_url, filter)
      Bridge.close_document!(conn, doc)
      {:ok, output_path}
    after
      Bridge.close!(conn)
    end
  end

  @doc """
  Convert document bytes to PDF via XInputStream/XOutputStream.

  No shared filesystem needed — bytes are streamed over the URP socket.

  ## Options

    * `:host`   — soffice hostname (default `"localhost"`)
    * `:port`   — soffice URP listener port (default `2002`)
    * `:filter` — [export filter name](https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html) (default `"writer_pdf_Export"`)
    * `:sink`   — output destination (see below)

  ## Sink

  Controls where the converted output goes:

    * omitted — accumulate in memory, returns `{:ok, binary}`
    * `{:path, path}` — write to file as chunks arrive, returns `:ok`
    * `fun/1` — call with each chunk as it arrives, returns `:ok`

  ## Examples

      {:ok, pdf_bytes} = URP.convert_stream(docx_bytes)
      :ok = URP.convert_stream(docx_bytes, sink: {:path, "/tmp/output.pdf"})
      :ok = URP.convert_stream(docx_bytes, sink: fn chunk -> IO.binwrite(fd, chunk) end)
  """
  @spec convert_stream(binary(), [stream_opt()]) :: {:ok, binary()} | :ok
  def convert_stream(input_bytes, opts \\ []) when is_binary(input_bytes) do
    {conn_opts, store_opts} = split_opts(opts)
    conn = Bridge.open!(conn_opts.host, conn_opts.port)

    try do
      doc = Bridge.load_document_stream!(conn, input_bytes)
      result = Bridge.store_to_stream!(conn, doc, store_opts)
      wrap_result(result)
    after
      Bridge.close!(conn)
    end
  end

  @doc """
  Convert a local file to PDF via streaming, without loading it all into memory.

  Reads from the file on demand as soffice requests chunks. The file only needs
  to be accessible to the Elixir node, not to soffice.

  Accepts the same options as `convert_stream/2`.
  """
  @spec convert_file_stream(Path.t(), [stream_opt()]) :: {:ok, binary()} | :ok
  def convert_file_stream(input_path, opts \\ []) when is_binary(input_path) do
    {conn_opts, store_opts} = split_opts(opts)
    conn = Bridge.open!(conn_opts.host, conn_opts.port)

    try do
      doc = Bridge.load_document_file_stream!(conn, input_path)
      result = Bridge.store_to_stream!(conn, doc, store_opts)
      wrap_result(result)
    after
      Bridge.close!(conn)
    end
  end

  defp split_opts(opts) do
    conn_opts = %{
      host: Keyword.get(opts, :host, "localhost"),
      port: Keyword.get(opts, :port, 2002)
    }

    store_opts = Keyword.take(opts, [:filter, :sink])
    {conn_opts, store_opts}
  end

  defp wrap_result(:ok), do: :ok
  defp wrap_result(bytes) when is_binary(bytes), do: {:ok, bytes}
end
