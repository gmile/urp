# Simple benchmark: URP vs CLI shell-out vs Gotenberg
#
# Record each service's LibreOffice version when comparing benchmark results.
#
# Prerequisites:
#   1. soffice container on port 2002 (URP)
#   2. soffice-cli container with /fixtures mount (CLI — separate instance to avoid lock)
#   3. Gotenberg service from docker-compose.yml on GOTENBERG_PORT (HTTP API)
#
#   docker compose --file benchmarks/docker-compose.yml up --detach --wait
#
# Run:
#   nix develop --command mix run benchmarks/convert.exs
#
# Environment variables:
#   GOTENBERG_PORT  - Gotenberg HTTP port (default: 3002)
#   SOFFICE_CLI     - Container name for CLI (default: soffice-cli)
#   FIXTURE         - docx file in benchmarks/fixtures/ (default: sample3.docx)
#   ITERATIONS      - Number of timed runs per method (default: 5)

gotenberg_port = System.get_env("GOTENBERG_PORT", "3002")
soffice_cli = System.get_env("SOFFICE_CLI", "soffice-cli")
fixture = System.get_env("FIXTURE", "sample3.docx")
iterations = String.to_integer(System.get_env("ITERATIONS", "5"))

docx_path = Path.expand("benchmarks/fixtures/#{fixture}")
docx_bytes = File.read!(docx_path)
gotenberg_url = "http://localhost:#{gotenberg_port}/forms/libreoffice/convert"
pdf_stem = Path.rootname(fixture)

IO.puts("Fixture:    #{fixture} (#{div(byte_size(docx_bytes), 1024)} KB)")
IO.puts("Iterations: #{iterations}")
IO.puts("CLI:        #{soffice_cli}")
IO.puts("Gotenberg:  #{gotenberg_url}")
IO.puts("")

bench = fn label, n, fun ->
  # Warmup (not timed)
  fun.()

  times =
    for i <- 1..n do
      t0 = System.monotonic_time(:millisecond)
      fun.()
      elapsed = System.monotonic_time(:millisecond) - t0
      IO.puts("  #{label} ##{i}: #{elapsed}ms")
      elapsed
    end

  avg = div(Enum.sum(times), n)
  min = Enum.min(times)
  max = Enum.max(times)
  IO.puts("  #{label} avg=#{avg}ms  min=#{min}ms  max=#{max}ms")
  IO.puts("")
end

# --- URP ---

bench.("URP", iterations, fn ->
  {:ok, _pdf} =
    URP.convert({:binary, docx_bytes}, filter: "writer_pdf_Export", output: :binary)
end)

# --- CLI ---

bench.("CLI", iterations, fn ->
  {_, 0} =
    System.cmd("docker", [
      "exec", soffice_cli, "soffice",
      "--headless", "--convert-to", "pdf",
      "--outdir", "/tmp",
      "/fixtures/#{fixture}"
    ])

  System.cmd("docker", ["exec", soffice_cli, "rm", "-f", "/tmp/#{pdf_stem}.pdf"])
end)

# --- Gotenberg ---

bench.("Gotenberg", iterations, fn ->
  {_pdf, 0} =
    System.cmd("curl", [
      "--silent", "--request", "POST", gotenberg_url,
      "--form", "files=@#{docx_path}",
      "--output", "-"
    ])
end)
