defmodule URP.StreamTest do
  use ExUnit.Case, async: true

  alias URP.Stream, as: URPStream

  test "enumerable reader advances only when requested" do
    owner = self()

    enumerable =
      Stream.resource(
        fn -> 0 end,
        fn value ->
          send(owner, {:produced, value})
          {[Integer.to_string(value)], value + 1}
        end,
        fn _value -> send(owner, :reader_closed) end
      )

    reader = URPStream.start_enum_reader(enumerable)

    refute_receive {:produced, _}

    send(reader, {:next, self()})
    assert_receive {:produced, 0}
    assert_receive {^reader, {:chunk, "0"}}
    refute_receive {:produced, 1}

    send(reader, {:next, self()})
    assert_receive {:produced, 1}
    assert_receive {^reader, {:chunk, "1"}}

    assert :ok = URPStream.stop_enum_reader(reader)
    assert_receive :reader_closed
    refute Process.alive?(reader)
  end

  test "enumerable reader reports producer failures without exiting the caller" do
    enumerable = Stream.map([:chunk], fn _ -> raise "reader exploded" end)
    reader = URPStream.start_enum_reader(enumerable)

    send(reader, {:next, self()})

    assert_receive {^reader, {:error, "reader exploded"}}
    refute Process.alive?(reader)
    assert Process.alive?(self())
  end

  test "enumerable reader exits when its owner dies" do
    parent = self()

    owner =
      spawn(fn ->
        reader = URPStream.start_enum_reader(Stream.cycle(["chunk"]))
        send(parent, {:reader, reader})

        receive do
          :stop_owner -> :ok
        end
      end)

    assert_receive {:reader, reader}
    ref = Process.monitor(reader)
    send(owner, :stop_owner)

    assert_receive {:DOWN, ^ref, :process, ^reader, :normal}
  end
end
