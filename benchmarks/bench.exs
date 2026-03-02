# End-to-end benchmark: URP vs Gotenberg
#
# Uses the high-level URP.convert/2 API (through the Pool) and compares
# against Gotenberg's HTTP API. Exercises the real production codepath.
#
# Prerequisites:
#   docker compose --file benchmarks/docker-compose.yml up --detach --wait
#
# Run:
#   nix develop --command mix run benchmarks/bench.exs

fixture = System.get_env("FIXTURE", "benchmark.docx")

docx_path = Path.expand("benchmarks/fixtures/#{fixture}")
docx_bytes = File.read!(docx_path)
gotenberg_url = "http://localhost:3002/forms/libreoffice/convert"

IO.puts("Fixture: #{fixture} (#{div(byte_size(docx_bytes), 1024)} KB)\n")

# Gotenberg-equivalent FilterData — matches DefaultOptions() from
# https://github.com/gotenberg/gotenberg/blob/v8.27.0/pkg/modules/libreoffice/api/api.go
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

urp_opts = [filter: "writer_pdf_Export", filter_data: gotenberg_filter_data, output: :binary]

# ── Gotenberg setup ──

Application.ensure_all_started(:telemetry)
{:ok, _} = Finch.start_link(name: Req.Finch)
form_data = [files: {docx_bytes, filename: fixture, content_type: "application/octet-stream"}]

# ── Debian pool (port 2003) ──

{:ok, _} = URP.Pool.start_link(name: :debian, host: "localhost", port: 2003, pool_size: 1)

# ── Warmup all services ──

{:ok, _} = URP.convert({:binary, docx_bytes}, urp_opts)
{:ok, _} = URP.Pool.convert(:debian, {:binary, docx_bytes}, urp_opts)
Req.post!(gotenberg_url, form_multipart: form_data)

# ── Benchmark ──

Benchee.run(
  %{
    "URP → Alpine musl" => fn ->
      {:ok, pdf} = URP.convert({:binary, docx_bytes}, urp_opts)
      pdf
    end,
    "URP → Debian glibc" => fn ->
      {:ok, pdf} = URP.Pool.convert(:debian, {:binary, docx_bytes}, urp_opts)
      pdf
    end,
    "Gotenberg (HTTP)" => fn ->
      %{status: 200, body: pdf} = Req.post!(gotenberg_url, form_multipart: form_data)
      pdf
    end
  },
  warmup: 2,
  time: 15,
  parallel: 1,
  formatters: [Benchee.Formatters.Console]
)
