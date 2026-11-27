# How fast bytes move to soffice and back, without converting anything: a
# file of the given size is written to its temp directory and read back, in
# chunks of several sizes.
#
#   mix run benchmarks/transfer.exs [megabytes]

alias URP.UNO

megabytes = System.argv() |> List.first("50") |> String.to_integer()
bytes = :crypto.strong_rand_bytes(megabytes * 1024 * 1024)
ms = fn fun -> fun |> :timer.tc() |> elem(0) |> div(1000) end

transfer = fn chunk ->
  fn conn ->
    url = "file:///tmp/urp_transfer_#{System.unique_integer([:positive])}"
    output = UNO.call(conn, conn.file_access, :open_file_write, [url])

    up =
      ms.(fn ->
        for offset <- 0..(byte_size(bytes) - 1)//chunk do
          UNO.call(conn, output, :write_bytes, [
            binary_part(bytes, offset, min(chunk, byte_size(bytes) - offset))
          ])
        end
      end)

    UNO.call(conn, output, :close_output)
    input = UNO.call(conn, conn.file_access, :open_file_read, [url])

    down =
      ms.(fn ->
        for _ <- 0..(byte_size(bytes) - 1)//chunk, do: UNO.call(conn, input, :read_bytes, [chunk])
      end)

    UNO.call(conn, input, :close_input)
    UNO.call(conn, conn.file_access, :kill, [url])
    {up, down}
  end
end

IO.puts("#{megabytes} MiB each way\n\n     chunk    up, ms  down, ms")

for kib <- [64, 256, 1024, 4096] do
  runs =
    for _ <- 1..3,
        do: URP.Pool.run(URP.ensure_pool!(nil), :transfer, [], transfer.(kib * 1024)) |> elem(1)

  {up, down} =
    {runs |> Enum.map(&elem(&1, 0)) |> Enum.min(), runs |> Enum.map(&elem(&1, 1)) |> Enum.min()}

  IO.puts(Enum.map_join(["#{kib} KiB", up, down], &String.pad_leading(to_string(&1), 10)))
end
