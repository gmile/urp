# What the VM spends on a run of conversions: CPU time and garbage collected
# per conversion, then the functions with the most time and the most memory
# allocated in them. The library is profiled from outside, with tprof.
#
#   mix run benchmarks/profile.exs path/to/document [count] [filter]

Mix.ensure_application!(:tools)

[file | rest] = System.argv()
count = rest |> Enum.at(0, "100") |> String.to_integer()
filter = Enum.at(rest, 1, "writer_pdf_Export")
bytes = File.read!(file)
convert = fn -> {:ok, _} = URP.convert({:binary, bytes}, filter: filter, output: :binary) end
run = fn -> for _ <- 1..count, do: convert.() end
each = &Float.round(&1 / count, 2)

{:ok, output} = convert.()
:erlang.statistics(:runtime)
{_, words_before, _} = :erlang.statistics(:garbage_collection)
{wall, _} = :timer.tc(run)
{_, cpu} = :erlang.statistics(:runtime)
{_, words_after, _} = :erlang.statistics(:garbage_collection)

IO.puts(
  "#{Path.basename(file)}: #{byte_size(bytes)} bytes in, #{byte_size(output)} bytes out, #{count} conversions"
)

IO.puts(
  "each: #{each.(wall / 1000)} ms, #{each.(cpu)} ms of CPU in the VM, #{each.((words_after - words_before) / 128)} KiB collected"
)

for {type, unit} <- [call_time: "us", call_memory: "words"] do
  :tprof.start(%{type: type})
  :tprof.enable_trace(:all)
  :tprof.set_pattern(:_, :_, :_)
  run.()
  :tprof.disable_trace(:all)
  %{all: {^type, total, rows}} = :tprof.inspect(:tprof.collect(), :total, :measurement)
  :tprof.stop()

  IO.puts("\n#{type}, #{each.(total)} #{unit} each:")

  for {module, {function, arity}, calls, value, _per_call, share} <-
        rows |> Enum.reverse() |> Enum.take(12) do
    columns = ["#{Float.round(share, 1)}%", each.(value), each.(calls)]

    IO.puts(
      Enum.map_join(columns, &String.pad_leading(to_string(&1), 10)) <>
        "  #{inspect(module)}.#{function}/#{arity}"
    )
  end
end
