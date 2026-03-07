# Benchmark I/O strategy combinations: io: :file vs io: :stream
#
# Tests all four input/output combinations through the Pool API.
#
# Prerequisites:
#   docker compose --file benchmarks/docker-compose.yml up --detach --wait
#
# Run (all fixtures):
#   nix develop --command mix run benchmarks/io_bench.exs
#
# Run (single fixture):
#   FIXTURES=benchmark.docx nix develop --command mix run benchmarks/io_bench.exs
#
# Environment:
#   FIXTURES — comma-separated filenames in benchmarks/fixtures/ (default: all)
#   FILTER   — export filter name (default: writer_pdf_Export)
#   PORT     — soffice port (default: 2003, the Debian glibc instance)
#
# Stream output overhead is negligible (<5%) regardless of file size.
# soffice writes in fixed 32767-byte chunks — a hardcoded literal in
# SfxMedium::Transfer_Impl(), not configurable via officecfg or UNO:
# https://github.com/LibreOffice/core/blob/libreoffice-26-2-0/sfx2/source/doc/docfile.cxx#L2573
#
# Stream input is the bottleneck (~40-50% slower) due to thousands of
# XInputStream/XSeekable round-trips for ZIP-based format random access.

default_fixtures = "benchmark.docx,benchmark-15mb.docx,benchmark-50mb.docx"
fixtures = System.get_env("FIXTURES", default_fixtures) |> String.split(",", trim: true)
filter = System.get_env("FILTER", "writer_pdf_Export")
port = System.get_env("PORT", "2003") |> String.to_integer()

Application.ensure_all_started(:telemetry)

{:ok, _} = URP.Pool.start_link(name: :bench, host: "localhost", port: port, pool_size: 1)

base_opts = [filter: filter, output: :binary]

inputs =
  for fixture <- fixtures, into: %{} do
    path = Path.expand("benchmarks/fixtures/#{fixture}")
    bytes = File.read!(path)
    mb = Float.round(byte_size(bytes) / 1_000_000, 1)
    {"#{mb} MB docx", bytes}
  end

# Warmup — first conversion primes soffice's font cache
{_label, first_bytes} = hd(Enum.to_list(inputs))
{:ok, _} = URP.Pool.convert(:bench, {:binary, first_bytes}, base_opts)

Benchee.run(
  %{
    "file → file" => fn bytes ->
      {:ok, _} = URP.Pool.convert(:bench, {:binary, bytes}, base_opts ++ [io: :file])
    end,
    "file → stream" => fn bytes ->
      {:ok, _} = URP.Pool.convert(:bench, {:binary, bytes}, base_opts ++ [io: {:file, :stream}])
    end,
    "stream → file" => fn bytes ->
      {:ok, _} = URP.Pool.convert(:bench, {:binary, bytes}, base_opts ++ [io: {:stream, :file}])
    end,
    "stream → stream" => fn bytes ->
      {:ok, _} = URP.Pool.convert(:bench, {:binary, bytes}, base_opts ++ [io: :stream])
    end
  },
  inputs: inputs,
  warmup: 2,
  time: 10,
  memory_time: 2,
  parallel: 1,
  formatters: [Benchee.Formatters.Console]
)
