# Simple benchmark: URP vs CLI shell-out vs Gotenberg
#
# Record each service's LibreOffice version when comparing benchmark results.
#
# Prerequisites:
#   1. soffice container on port 2002 (URP)
#   2. soffice-cli Compose service (CLI — separate instance to avoid profile locking)
#   3. Gotenberg service from docker-compose.yml on GOTENBERG_PORT (HTTP API)
#
#   docker compose --file benchmarks/docker-compose.yml up --detach --wait
#
# Run:
#   nix develop --command mix run benchmarks/convert.exs
#
# Environment variables:
#   GOTENBERG_PORT  - Gotenberg HTTP port (default: 3002)
#   SOFFICE_CLI     - Compose service name for CLI (default: soffice-cli)
#   FIXTURE         - fixture in benchmarks/fixtures or test/fixtures (default: sample3.docx)
#   ITERATIONS      - Number of timed runs per method (default: 10)

gotenberg_port = System.get_env("GOTENBERG_PORT", "3002")
soffice_cli = System.get_env("SOFFICE_CLI", "soffice-cli")
fixture = System.get_env("FIXTURE", "sample3.docx")
iterations = String.to_integer(System.get_env("ITERATIONS", "10"))
compose_file = Path.expand("benchmarks/docker-compose.yml")

{docx_path, container_fixture} =
  [
    {Path.expand("benchmarks/fixtures/#{fixture}"), "/benchmark-fixtures/#{fixture}"},
    {Path.expand("test/fixtures/#{fixture}"), "/test-fixtures/#{fixture}"}
  ]
  |> Enum.find(fn {path, _container_path} -> File.exists?(path) end) ||
    raise "fixture #{fixture} not found in benchmarks/fixtures or test/fixtures"

docx_bytes = File.read!(docx_path)
gotenberg_url = "http://localhost:#{gotenberg_port}/forms/libreoffice/convert"
pdf_stem = Path.rootname(fixture)

run! = fn command, args ->
  {output, status} = System.cmd(command, args, stderr_to_stdout: true)

  if status != 0 do
    raise "command failed (#{status}): #{command} #{Enum.join(args, " ")}\n#{output}"
  end

  output
end

compose! = fn args ->
  run!.("docker", ["compose", "--file", compose_file] ++ args)
end

assert_pdf! = fn label, bytes ->
  unless match?(<<"%PDF-", _::binary>>, bytes) do
    raise "#{label} did not produce a PDF (#{byte_size(bytes)} bytes)"
  end

  bytes
end

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
  {:ok, pdf} =
    URP.convert({:binary, docx_bytes}, filter: "writer_pdf_Export", output: :binary)

  assert_pdf!.("URP", pdf)
end)

# --- CLI ---

bench.("CLI", iterations, fn ->
  script = """
  set -eu
  output_dir=$(mktemp -d /tmp/urp-cli.XXXXXX)
  trap 'rm -rf "$output_dir"' EXIT

  if ! soffice --headless --convert-to pdf --outdir "$output_dir" "$2" \
      >"$output_dir/convert.log" 2>&1; then
    cat "$output_dir/convert.log" >&2
    exit 1
  fi

  cat "$output_dir/$1.pdf"
  """

  pdf =
    compose!.([
      "exec",
      "-T",
      soffice_cli,
      "sh",
      "-c",
      script,
      "urp-cli",
      pdf_stem,
      container_fixture
    ])

  assert_pdf!.("LibreOffice CLI", pdf)
end)

# --- Gotenberg ---

bench.("Gotenberg", iterations, fn ->
  pdf =
    run!.("curl", [
      "--silent",
      "--show-error",
      "--fail-with-body",
      "--request",
      "POST",
      gotenberg_url,
      "--form",
      "files=@#{docx_path}",
      "--output",
      "-"
    ])

  assert_pdf!.("Gotenberg", pdf)
end)
