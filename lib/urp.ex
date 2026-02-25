defmodule URP do
  @moduledoc """
  Pure Elixir client for document conversion via LibreOffice's UNO Remote Protocol.

  Talks directly to a `soffice` process over TCP.
  No Python, no unoserver, no Gotenberg.

  ## Direct usage (scripts, IEx, tests)

      {:ok, pdf_bytes} = URP.convert_stream(docx_bytes)
      {:ok, pdf_bytes} = URP.convert_file_stream("/path/to/input.docx")
      {:ok, output}    = URP.convert("/shared/input.docx", "/shared/output.pdf")

  ## Supervised usage (production)

  Add `URP.Connection` to your supervision tree for serialized access
  and backpressure:

      children = [
        {URP.Connection, host: "soffice", port: 2002}
      ]

      {:ok, pdf_bytes} = URP.Connection.convert_stream(docx_bytes)
  """

  alias URP.Bridge

  @doc """
  Convert a file to PDF via a running soffice instance.

  `input_path` and `output_path` must be accessible to soffice at those exact
  paths (e.g. via a shared volume mount when using Docker/Kubernetes).

  ## Options

    * `:host`   — soffice hostname (default `"localhost"`)
    * `:port`   — soffice URP listener port (default `2002`)
    * `:filter` — export filter name (default `"writer_pdf_Export"`)
  """
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
  Convert document bytes to PDF in memory via XInputStream/XOutputStream.

  No shared filesystem needed — bytes are streamed over the URP socket.

  ## Options

    * `:host`   — soffice hostname (default `"localhost"`)
    * `:port`   — soffice URP listener port (default `2002`)
    * `:filter` — export filter name (default `"writer_pdf_Export"`)
  """
  def convert_stream(input_bytes, opts \\ []) when is_binary(input_bytes) do
    {host, port, filter} = stream_opts(opts)
    conn = Bridge.open!(host, port)

    try do
      doc = Bridge.load_document_stream!(conn, input_bytes)
      pdf_bytes = Bridge.store_to_stream!(conn, doc, filter)
      {:ok, pdf_bytes}
    after
      Bridge.close!(conn)
    end
  end

  @doc """
  Convert a local file to PDF via streaming, without loading it all into memory.

  Reads from the file on demand as soffice requests chunks. The file only needs
  to be accessible to the Elixir node, not to soffice.

  ## Options

    * `:host`   — soffice hostname (default `"localhost"`)
    * `:port`   — soffice URP listener port (default `2002`)
    * `:filter` — export filter name (default `"writer_pdf_Export"`)
  """
  def convert_file_stream(input_path, opts \\ []) when is_binary(input_path) do
    {host, port, filter} = stream_opts(opts)
    conn = Bridge.open!(host, port)

    try do
      doc = Bridge.load_document_file_stream!(conn, input_path)
      pdf_bytes = Bridge.store_to_stream!(conn, doc, filter)
      {:ok, pdf_bytes}
    after
      Bridge.close!(conn)
    end
  end

  defp stream_opts(opts) do
    {
      Keyword.get(opts, :host, "localhost"),
      Keyword.get(opts, :port, 2002),
      Keyword.get(opts, :filter, "writer_pdf_Export")
    }
  end
end
