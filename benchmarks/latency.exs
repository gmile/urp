# How long a conversion takes, over a run of them on one connection: the
# fastest, the median, the 99th percentile and the slowest, and how many a
# second that makes.
#
#   mix run benchmarks/latency.exs path/to/document [count] [filter]

[file | rest] = System.argv()
count = rest |> Enum.at(0, "100") |> String.to_integer()
filter = Enum.at(rest, 1, "writer_pdf_Export")
bytes = File.read!(file)
convert = fn -> {:ok, _} = URP.convert({:binary, bytes}, filter: filter, output: :binary) end

{:ok, output} = convert.()
times = for(_ <- 1..count, do: convert |> :timer.tc() |> elem(0)) |> Enum.sort()
at = fn share -> Enum.at(times, min(round(share * count), count - 1)) end
ms = &:erlang.float_to_binary(&1 / 1000, decimals: 1)

IO.puts(
  "#{Path.basename(file)}: #{byte_size(bytes)} bytes in, #{byte_size(output)} bytes out, #{count} conversions"
)

IO.puts(
  "fastest #{ms.(hd(times))} ms, median #{ms.(at.(0.5))} ms, 99th percentile #{ms.(at.(0.99))} ms, slowest #{ms.(List.last(times))} ms"
)

IO.puts("#{Float.round(count * 1_000_000 / Enum.sum(times), 1)} conversions a second")
