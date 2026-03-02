# Phase-level timing: URP vs Gotenberg
#
# Breaks each conversion into measurable phases to find where time is spent.
#
# Prerequisites: soffice on 2002, gotenberg on 3002
#
# Run:
#   nix develop --command mix run benchmarks/profile.exs

alias URP.Bridge

fixture = System.get_env("FIXTURE", "sample4.docx")
iterations = String.to_integer(System.get_env("ITERATIONS", "5"))
gotenberg_port = System.get_env("GOTENBERG_PORT", "3002")

docx_path = Path.expand("benchmarks/fixtures/#{fixture}")
docx_bytes = File.read!(docx_path)
gotenberg_url = "http://localhost:#{gotenberg_port}/forms/libreoffice/convert"

IO.puts("Fixture: #{fixture} (#{div(byte_size(docx_bytes), 1024)} KB)")
IO.puts("Iterations: #{iterations}\n")

# Gotenberg-equivalent FilterData — matches DefaultOptions() from
# https://github.com/gotenberg/gotenberg/blob/v8.23.1/pkg/modules/libreoffice/api/api.go#L156-L186
gotenberg_filter_data = [
  ExportFormFields: true,
  AllowDuplicateFieldNames: false,
  ExportBookmarks: true,
  ExportBookmarksToPDFDestination: false,
  ExportPlaceholders: false,
  ExportNotes: false,
  ExportNotesPages: false,
  ExportOnlyNotesPages: false,
  ExportNotesInMargin: false,
  ConvertOOoTargetToPDFTarget: false,
  ExportLinksRelativeFsys: false,
  ExportHiddenSlides: false,
  IsSkipEmptyPages: false,
  IsAddStream: false,
  SinglePageSheets: false,
  UseLosslessCompression: false,
  Quality: 90,
  ReduceImageResolution: false,
  MaxImageResolution: 300,
  PDFUACompliance: false,
  UseTaggedPDF: false,
  EnableTextAccessForAccessibilityTools: false
]

filter_opts = [filter: "writer_pdf_Export", filter_data: gotenberg_filter_data]

# ── Pre-place file in soffice container (bypasses network transfer) ──

{_, 0} = System.cmd("docker", ["cp", docx_path, "soffice:/tmp/bench_local.docx"])

# ── URP setup ──

conn = Bridge.open!("localhost", 2002)

if conn.tid_cache != %{} do
  existing = Process.get(:urp_tid_cache, %{})
  Process.put(:urp_tid_cache, Map.merge(conn.tid_cache, existing))
end

# Warmup (primes SFA cache)
{doc, conn, url} = Bridge.load_document_write!(conn, docx_bytes)
_pdf = Bridge.store_to_stream!(conn, doc, filter_opts)
Bridge.close_document!(conn, doc)
Bridge.delete_file!(conn, url)
URP.Stream.clear_input_ctx()

# ── Experiment 1: full URP path (write + load + convert + stream back) ──

IO.puts("═══ URP full path (write → load → convert → stream back) ═══\n")

conn =
  Enum.reduce(1..iterations, conn, fn i, conn ->
    {t_write, {doc, conn, url}} =
      :timer.tc(fn -> Bridge.load_document_write!(conn, docx_bytes) end)

    {t_store, pdf} =
      :timer.tc(fn -> Bridge.store_to_stream!(conn, doc, filter_opts) end)

    {t_close, _} =
      :timer.tc(fn ->
        Bridge.close_document!(conn, doc)
        Bridge.delete_file!(conn, url)
      end)

    URP.Stream.clear_input_ctx()
    total = t_write + t_store + t_close

    IO.puts(
      "  ##{i}  write+load=#{div(t_write, 1000)}ms  convert+stream=#{div(t_store, 1000)}ms  " <>
        "cleanup=#{div(t_close, 1000)}ms  TOTAL=#{div(total, 1000)}ms  (#{div(byte_size(pdf), 1024)}KB)"
    )

    conn
  end)

# ── Experiment 2: full URP path with file-based output (write → load → convert → file read-back) ──

IO.puts("\n═══ URP full path + file output (write → load → store_to_url → read back) ═══\n")

conn =
  Enum.reduce(1..iterations, conn, fn i, conn ->
    {t_write, {doc, conn, url}} =
      :timer.tc(fn -> Bridge.load_document_write!(conn, docx_bytes) end)

    {t_store, {pdf, conn}} =
      :timer.tc(fn ->
        Bridge.store_document_write!(conn, doc, filter_opts)
      end)

    {t_close, _} =
      :timer.tc(fn ->
        Bridge.close_document!(conn, doc)
        Bridge.delete_file!(conn, url)
      end)

    URP.Stream.clear_input_ctx()
    total = t_write + t_store + t_close

    IO.puts(
      "  ##{i}  write+load=#{div(t_write, 1000)}ms  convert+readback=#{div(t_store, 1000)}ms  " <>
        "cleanup=#{div(t_close, 1000)}ms  TOTAL=#{div(total, 1000)}ms  (#{div(byte_size(pdf), 1024)}KB)"
    )

    conn
  end)

# ── Experiment 3: local file:// load (no network transfer) ──

IO.puts("\n═══ URP local file (no transfer — file:// load → convert → stream back) ═══\n")

for i <- 1..iterations do
  {t_load, doc} =
    :timer.tc(fn -> Bridge.load_document!(conn, "file:///tmp/bench_local.docx") end)

  {t_store, pdf} =
    :timer.tc(fn -> Bridge.store_to_stream!(conn, doc, filter_opts) end)

  {t_close, _} = :timer.tc(fn -> Bridge.close_document!(conn, doc) end)
  URP.Stream.clear_input_ctx()

  total = t_load + t_store + t_close

  IO.puts(
    "  ##{i}  load=#{div(t_load, 1000)}ms  convert+stream=#{div(t_store, 1000)}ms  " <>
      "cleanup=#{div(t_close, 1000)}ms  TOTAL=#{div(total, 1000)}ms  (#{div(byte_size(pdf), 1024)}KB)"
  )
end

Bridge.close!(conn)

# ── Gotenberg: Req HTTP client ──

IO.puts("\n═══ Gotenberg via Req (HTTP multipart upload → convert → download) ═══\n")

Application.ensure_all_started(:telemetry)
{:ok, _} = Finch.start_link(name: Req.Finch)

form_data = [files: {docx_bytes, filename: fixture, content_type: "application/octet-stream"}]

# Warmup
Req.post!(gotenberg_url, form_multipart: form_data)

for i <- 1..iterations do
  {t_total, resp} =
    :timer.tc(fn -> Req.post!(gotenberg_url, form_multipart: form_data) end)

  pdf_size = byte_size(resp.body)

  IO.puts("  ##{i}  total=#{div(t_total, 1000)}ms  (#{div(pdf_size, 1024)}KB)")
end

IO.puts("")
