# How fast bytes move to soffice and back, without converting anything. Up is
# one message, as a document is sent; down is a pipe in soffice's memory read
# in chunks of several sizes, as a result is.
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
  time = ms.(fn -> Process.put(:stream, UNO.call(conn, conn.service_manager, :create_instance_with_arguments_and_context, args)) end)
  Connection.release(conn, Process.get(:stream))
  time
end

down = fn chunk ->
  fn conn ->
    pipe = UNO.create_instance(conn, "com.sun.star.io.Pipe")
    Connection.call(conn, pipe, "com.sun.star.io.XOutputStream", 3, [bytes: bytes], :void)
    time = ms.(fn -> for at <- 0..(byte_size(bytes) - 1)//chunk, do: UNO.call(conn, pipe, :read_bytes, [min(chunk, byte_size(bytes) - at)]) end)
    Connection.release(conn, pipe)
    time
  end
end

IO.puts("#{megabytes} MiB up in one message: #{best.(up)} ms\n\ndown, by chunk:")
for kib <- [64, 256, 1024, 4096], do: IO.puts(String.pad_leading("#{kib} KiB", 10) <> String.pad_leading("#{best.(down.(kib * 1024))} ms", 10))
