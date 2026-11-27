# Every round trip one conversion makes to soffice: how long it took, the
# bytes sent and received, and the UNO method with its arguments, named as the
# LibreOffice API reference names it. The library is traced from outside.
#
#   mix run benchmarks/calls.exs path/to/document [filter]

[file | rest] = System.argv()
filter = List.first(rest) || "writer_pdf_Export"
bytes = File.read!(file)
convert = fn -> URP.convert({:binary, bytes}, filter: filter, output: :binary) end
{:ok, _} = convert.()

short = &(&1 |> String.split(".") |> List.last())

# `:store_to_url` on XStorable2 is `XStorable2.storeToURL` in the API reference.
name = fn interface, method ->
  [first | words] = method |> Atom.to_string() |> String.split("_")

  short.(interface) <>
    "." <> first <> Enum.map_join(words, &if(&1 == "url", do: "URL", else: String.capitalize(&1)))
end

# A document shows as its size, an object as a placeholder, properties by name.
show = fn
  show, :bytes, value -> "<#{byte_size(value)} bytes>"
  show, :type, value -> short.(value)
  show, :any, {type, value} -> show.(show, type, value)
  _show, {:interface, _}, _oid -> "<object>"
  show, {:sequence, _}, items -> "[" <> Enum.map_join(items, ", ", &show.(show, :item, &1)) <> "]"
  show, :item, {{:struct, _, _}, [name, value]} -> "#{name}: #{show.(show, :any, value)}"
  show, :item, {type, value} -> show.(show, type, value)
  show, :item, [name, _handle, value, _state] -> "#{name}: #{show.(show, :any, value)}"
  _show, _type, value -> inspect(value, printable_limit: 60)
end

functions = [
  {URP.UNO, :call, 4},
  {URP.Connection, :invoke, 5},
  {URP.Protocol, :send_frame, 2},
  {URP.Protocol, :recv_frame, 2}
]

for mfa <- functions, do: :erlang.trace_pattern(mfa, [{:_, [], [{:return_trace}]}], [:local])
:erlang.trace(:processes, true, [:call, :timestamp])
{total, {:ok, output}} = :timer.tc(convert)
:erlang.trace(:processes, false, [:call])

events =
  Stream.repeatedly(fn -> receive(do: (event -> event), after: (0 -> nil)) end)
  |> Enum.take_while(& &1)

# A call is open from its request going out to its reply coming back; the
# frames sent and received in between are its traffic.
{calls, _method, _open} =
  Enum.reduce(events, {[], nil, nil}, fn
    {_, _, :call, {URP.UNO, :call, [_conn, _object, method, _args]}, _at}, {calls, _, open} ->
      {calls, method, open}

    {_, _, :call, {URP.Connection, :invoke, [_conn, _oid, interface, function, args]}, at},
    {calls, method, _} ->
      label = if function == 0, do: "XInterface.queryInterface", else: name.(interface, method)
      shown = Enum.map_join(args, ", ", fn {type, value} -> show.(show, type, value) end)
      {calls, method, %{call: "#{label}(#{shown})", at: at, sent: 0, received: 0}}

    {_, _, :call, {URP.Protocol, :send_frame, [_sock, frame]}, _at},
    {calls, method, %{} = open} ->
      {calls, method, %{open | sent: open.sent + 8 + IO.iodata_length(frame)}}

    {_, _, :return_from, {URP.Protocol, :recv_frame, 2}, frame, _at},
    {calls, method, %{} = open} ->
      {calls, method, %{open | received: open.received + 8 + byte_size(frame)}}

    {_, _, :return_from, {URP.Connection, :invoke, 5}, _reply, at}, {calls, method, open} ->
      {[Map.put(open, :ms, :timer.now_diff(at, open.at) / 1000) | calls], method, nil}

    _other, state ->
      state
  end)

calls = Enum.reverse(calls)
sum = fn key -> calls |> Enum.map(& &1[key]) |> Enum.sum() end

row = fn columns, call ->
  IO.puts(Enum.map_join(columns, &String.pad_leading(to_string(&1), 13)) <> "  " <> call)
end

ms = &:erlang.float_to_binary(&1 / 1, decimals: 2)

IO.puts(
  "#{Path.basename(file)}: #{byte_size(bytes)} bytes in, #{byte_size(output)} bytes out, #{filter}\n"
)

row.(["time, ms", "sent, B", "received, B"], "call")
for call <- calls, do: row.([ms.(call.ms), call.sent, call.received], call.call)

row.(
  [ms.(sum.(:ms)), sum.(:sent), sum.(:received)],
  "in #{length(calls)} round trips, of #{ms.(total / 1000)} ms in all"
)
