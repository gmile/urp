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
