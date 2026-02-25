defmodule URP do
  @moduledoc """
  Pure Elixir client for document conversion via LibreOffice's UNO Remote Protocol.

  Talks directly to a `soffice` process over TCP.
  No Python, no unoserver, no Gotenberg.

  ## File-based conversion

      URP.convert("/shared/input.docx", "/shared/output.pdf")

      URP.convert("/shared/input.docx", "/shared/output.pdf",
        host: "soffice",
        port: 2002,
        filter: "writer_pdf_Export"
      )

  Both paths must be accessible to the soffice process (shared filesystem).

  ## Stream-based conversion (planned)

      {:ok, pdf_bytes} = URP.convert(docx_bytes, filter: "writer_pdf_Export")

  Uses `XInputStream`/`XOutputStream` to transfer bytes over the URP socket.
  No shared filesystem required.
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
end
