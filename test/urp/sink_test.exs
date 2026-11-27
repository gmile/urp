defmodule URP.SinkTest do
  use ExUnit.Case, async: true

  alias URP.Sink

  test "collects what is written to memory" do
    sink = :binary |> Sink.open() |> Sink.write("ab") |> Sink.write("cd")

    assert Sink.finish(sink) == "abcd"
  end

  test "writes to a file" do
    path = Path.join(System.tmp_dir!(), "urp_sink_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)

    assert :ok =
             {:path, path} |> Sink.open() |> Sink.write("ab") |> Sink.write("cd") |> Sink.finish()

    assert File.read!(path) == "abcd"
  end

  test "reports a file it cannot open" do
    assert_raise URP.Error, ~r/could not open output/, fn ->
      Sink.open({:path, "/nonexistent-directory/out.pdf"})
    end
  end

  test "raises when its function does, whatever the function does" do
    for fun <- [
          fn _ -> raise "sink exploded" end,
          fn _ -> exit(:boom) end,
          fn _ -> throw(:ball) end
        ] do
      assert_raise URP.Error, ~r/^output sink failed: /, fn ->
        fun |> Sink.open() |> Sink.write("ab")
      end
    end
  end
end
