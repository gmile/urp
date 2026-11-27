# How fast bytes move to soffice and back, without converting anything. Up is
# one message, as a document is sent; down is a temp file read back in chunks
# of several sizes, as a result is.
#
#   mix run benchmarks/transfer.exs [megabytes]

alias URP.{Connection, UNO}

megabytes = System.argv() |> List.first("50") |> String.to_integer()
bytes = :crypto.strong_rand_bytes(megabytes * 1024 * 1024)
ms = fn fun -> fun |> :timer.tc() |> elem(0) |> div(1000) end
run = fn job -> URP.Pool.run(URP.ensure_pool!(nil), :transfer, [], job) |> elem(1) end
best = fn job -> Enum.min(for _ <- 1..3, do: run.(job)) end

up = fn conn ->
  args = ["com.sun.star.io.SequenceInputStream", [{:bytes, bytes}], conn.context]
  ms.(fn -> conn |> UNO.call(conn.service_manager, :create_instance_with_arguments_and_context, args) |> then(&Connection.release(conn, &1)) end)
end

# The file to read back is written through the same file access the result of
# a conversion is read through.
down = fn chunk ->
  fn conn ->
    url = "file:///tmp/urp_transfer_#{System.unique_integer([:positive])}"
    output = Connection.call(conn, conn.file_access, "com.sun.star.ucb.XSimpleFileAccess", 16, [string: url], {:interface, "com.sun.star.io.XOutputStream"})
    Connection.call(conn, output, "com.sun.star.io.XOutputStream", 3, [bytes: bytes], :void)
    Connection.call(conn, output, "com.sun.star.io.XOutputStream", 5, [], :void)

    input = UNO.call(conn, conn.file_access, :open_file_read, [url])
    time = ms.(fn -> for _ <- 0..(byte_size(bytes) - 1)//chunk, do: UNO.call(conn, input, :read_bytes, [chunk]) end)
    UNO.call(conn, input, :close_input)
    UNO.call(conn, conn.file_access, :kill, [url])
    time
  end
end

IO.puts("#{megabytes} MiB up in one message: #{best.(up)} ms\n\ndown, by chunk:")
for kib <- [64, 256, 1024, 4096], do: IO.puts(String.pad_leading("#{kib} KiB", 10) <> String.pad_leading("#{best.(down.(kib * 1024))} ms", 10))
