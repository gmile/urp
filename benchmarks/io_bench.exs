# Benchmark I/O strategy combinations: io: :file vs io: :stream
#
# Tests all four input/output combinations through the Pool API.
#
# Prerequisites:
#   docker compose --file benchmarks/docker-compose.yml up --detach --wait
#
# Run:
#   nix develop --command mix run benchmarks/io_bench.exs
#
# Environment:
#   FIXTURE  — filename in benchmarks/fixtures/ (default: benchmark.docx)
#   FILTER   — export filter name (default: writer_pdf_Export)
#   PORT     — soffice port (default: 2003, the Debian glibc instance)
#
# Results (M3 Max, Debian soffice 26.2.0.3):
#
#   2.6 MB docx → 7 MB PDF:
#     file→file:     1.20 s (baseline)
#     file→stream:   1.21 s (1.01x) — 223 writeBytes calls
#     stream→stream: 1.69 s (1.41x)
#     stream→file:   1.81 s (1.51x)
#
#   15 MB docx → 42 MB PDF:
#     file→file:     7.67 s (baseline)
#     file→stream:   8.00 s (1.04x) — 1310 writeBytes calls
#
# Stream output overhead is negligible (<5%) regardless of file size.
# soffice writes in fixed 32767-byte chunks — a hardcoded literal in
# SfxMedium::Transfer_Impl(), not configurable via officecfg or UNO:
# https://github.com/LibreOffice/core/blob/libreoffice-26-2-0/sfx2/source/doc/docfile.cxx#L2573
#
# Stream input is the bottleneck (~40-50% slower) due to thousands of
# XInputStream/XSeekable round-trips for ZIP-based format random access.

fixture = System.get_env("FIXTURE", "benchmark.docx")
filter = System.get_env("FILTER", "writer_pdf_Export")
port = System.get_env("PORT", "2003") |> String.to_integer()

docx_path = Path.expand("benchmarks/fixtures/#{fixture}")
bytes = File.read!(docx_path)

IO.puts("Fixture: #{fixture} (#{div(byte_size(bytes), 1024)} KB)")
IO.puts("Filter:  #{filter}")
IO.puts("Port:    #{port}\n")

Application.ensure_all_started(:telemetry)

{:ok, _} = URP.Pool.start_link(name: :bench, host: "localhost", port: port, pool_size: 1)

base_opts = [filter: filter, output: :binary]

# Warmup — first conversion primes soffice's font cache
{:ok, pdf} = URP.Pool.convert(:bench, {:binary, bytes}, base_opts)
IO.puts("Warmup: #{div(byte_size(pdf), 1024)} KB PDF\n")

Benchee.run(
  %{
    "file → file (production)" => fn ->
      {:ok, _} = URP.Pool.convert(:bench, {:binary, bytes}, base_opts ++ [io: :file])
    end,
    "file → stream" => fn ->
      {:ok, _} = URP.Pool.convert(:bench, {:binary, bytes}, base_opts ++ [io: {:file, :stream}])
    end,
    "stream → file" => fn ->
      {:ok, _} = URP.Pool.convert(:bench, {:binary, bytes}, base_opts ++ [io: {:stream, :file}])
    end,
    "stream → stream" => fn ->
      {:ok, _} = URP.Pool.convert(:bench, {:binary, bytes}, base_opts ++ [io: :stream])
    end
  },
  warmup: 2,
  time: 15,
  parallel: 1,
  formatters: [Benchee.Formatters.Console]
)
