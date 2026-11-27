defmodule URPTest do
  use ExUnit.Case, async: false

  import URP.TestFixtures

  @moduletag :integration
  @moduletag timeout: 15_000

  @pdf "writer_pdf_Export"

  # "Text" gives output that can be compared; a PDF differs from run to run.
  defp text(input, opts \\ []) do
    URP.convert(input, Keyword.merge([filter: "Text", output: :binary], opts))
  end

  defp tmp_path(ext) do
    path = Path.join(System.tmp_dir!(), "urp_test_#{System.unique_integer([:positive])}.#{ext}")
    on_exit(fn -> File.rm(path) end)
    path
  end

  # The page count from the PDF Pages dictionary (/Type /Pages ... /Count N).
  defp pdf_page_count(pdf) do
    [_, count] = Regex.run(~r|/Type\s*/Pages.*?/Count\s+(\d+)|s, pdf)
    String.to_integer(count)
  end

  describe "convert/2" do
    test "takes a document in memory and returns the result" do
      assert {:ok, text} = text({:binary, build_test_docx("In memory")})
      assert text =~ "In memory"
    end

    test "takes a file and writes a file" do
      input = tmp_path("docx")
      output = tmp_path("txt")
      File.write!(input, build_test_docx("On disk"))

      assert {:ok, ^output} = URP.convert(input, filter: "Text", output: output)
      assert File.read!(output) =~ "On disk"
    end

    test "reads the result back a chunk at a time" do
      port = Application.get_env(:urp, :default, [])[:port] || 2002
      Application.put_env(:urp, :pools, small_chunks: [port: port, chunk_size: 1024])
      on_exit(fn -> Application.delete_env(:urp, :pools) end)

      test = self()
      docx = File.read!("test/fixtures/sample3.docx")
      {:ok, whole} = text({:binary, docx})

      assert :ok = text({:binary, docx}, pool: :small_chunks, output: &send(test, {:chunk, &1}))

      chunks =
        for _ <- 1..ceil(byte_size(whole) / 1024) do
          assert_received {:chunk, chunk}
          chunk
        end

      refute_received {:chunk, _}
      assert Enum.all?(chunks, &(byte_size(&1) <= 1024))
      assert IO.iodata_to_binary(chunks) == whole
    end

    test "converts real documents in full" do
      docx = File.read!("test/fixtures/sample3.docx")
      xlsx = File.read!("test/fixtures/sample1.xlsx")

      assert {:ok, pdf} = URP.convert({:binary, docx}, filter: @pdf, output: :binary)
      assert pdf_page_count(pdf) >= 2

      assert {:ok, pdf} = URP.convert({:binary, xlsx}, filter: "calc_pdf_Export", output: :binary)
      assert pdf_page_count(pdf) >= 9
    end

    test "exports through any filter soffice has" do
      assert {:ok, markdown} =
               URP.convert({:binary, build_test_docx()}, filter: "Markdown", output: :binary)

      assert markdown =~ "Hello from URP smoke test"
    end

    test "applies settings, and says which one soffice does not have" do
      cache = "org.openoffice.Office.Common/Cache/GraphicManager"
      opts = [filter_data: [UseLosslessCompression: true, FormsType: 1]]

      settings = [
        {cache, "GraphicMemoryLimit", 500_000_000},
        {cache, "GraphicAllowedIdleTime", 20}
      ]

      assert {:ok, _text} = text({:binary, build_test_docx()}, [settings: settings] ++ opts)

      settings = [{cache, "NoSuchSetting", 1}]

      assert {:error, "NoSuchSetting"} =
               text({:binary, build_test_docx()}, [settings: settings] ++ opts)
    end
  end

  describe "a job that fails" do
    test "for want of its input says so, and the next one runs" do
      assert {:error, message} =
               text("/tmp/urp_missing_#{System.unique_integer([:positive])}.docx")

      assert message =~ "no such file"

      assert {:ok, _text} = text({:binary, build_test_docx()})
    end

    test "in soffice leaves no output file behind" do
      path = tmp_path("pdf")

      assert {:error, message} =
               URP.convert({:binary, build_test_docx()}, filter: "no-such-filter", output: path)

      assert is_binary(message)
      refute File.exists?(path)
    end

    test "in its output function says so, and the next one runs" do
      assert {:error, message} =
               text({:binary, build_test_docx()}, output: fn _chunk -> raise "sink exploded" end)

      assert message =~ "sink exploded"
      assert {:ok, _text} = text({:binary, build_test_docx()})
    end

    test "because its caller was killed does not stop the next" do
      docx = build_test_docx()

      for _ <- 1..5 do
        caller = spawn(fn -> text({:binary, docx}) end)
        Process.sleep(5)
        Process.exit(caller, :kill)
      end

      assert {:ok, _text} = text({:binary, docx})
    end
  end

  describe "a job that outlives its timeout" do
    def handle_drain(_event, measurements, metadata, test_pid) do
      send(test_pid, {:drain, measurements, metadata})
    end

    setup do
      :telemetry.attach(
        "drain-test",
        [:urp, :connection, :drain],
        &__MODULE__.handle_drain/4,
        self()
      )

      on_exit(fn -> :telemetry.detach("drain-test") end)
    end

    test "is seen through by the connection, which then takes the next" do
      slow = fn _chunk -> Process.sleep(300) end

      for _ <- 1..3 do
        assert {:error, :timeout} = text({:binary, build_test_docx()}, output: slow, timeout: 100)
        assert_receive {:drain, %{duration: duration}, %{result: :ok}}, 30_000
        assert duration > 0
      end

      assert {:ok, _text} = text({:binary, build_test_docx()})
    end
  end

  describe "two callers and one connection" do
    test "each gets its own document" do
      tasks =
        for n <- ["One", "Two"], do: Task.async(fn -> text({:binary, build_test_docx(n)}) end)

      assert [{:ok, one}, {:ok, two}] = Task.await_many(tasks, 15_000)
      assert one =~ "One"
      assert two =~ "Two"
    end
  end

  describe "diagnostics" do
    test "report on soffice, and their ! forms return the same" do
      assert {:ok, version} = URP.version()
      assert version =~ ~r/^\d+\.\d+/
      assert URP.version!() == version

      assert {:ok, locale} = URP.locale()
      assert URP.locale!() == locale

      assert "com.sun.star.frame.Desktop" in URP.services!()
      assert "writer_pdf_Export" in URP.filters!()
      assert "writer8" in URP.types!()
    end
  end

  describe "without soffice" do
    @describetag integration: false

    test "a stub gets the input and options, and answers for convert/2" do
      URP.Test.stub(fn input, opts ->
        assert input == {:binary, "bytes"}
        assert opts[:filter] == "calc_pdf_Export"
        {:ok, "stubbed"}
      end)

      assert {:ok, "stubbed"} =
               URP.convert({:binary, "bytes"}, filter: "calc_pdf_Export", output: :binary)
    end

    test "a task started by the test uses the test's stub" do
      URP.Test.stub(fn _input, _opts -> {:ok, "parent stub"} end)
      task = Task.async(fn -> URP.convert({:binary, "bytes"}, filter: @pdf, output: :binary) end)

      assert {:ok, "parent stub"} = Task.await(task)
    end

    test "a process the test allows uses the test's stub" do
      URP.Test.stub(fn _input, _opts -> {:ok, "allowed"} end)
      test = self()

      pid =
        spawn(fn ->
          receive do: (:go ->
                         send(test, URP.convert({:binary, "b"}, filter: @pdf, output: :binary)))
        end)

      URP.Test.allow(self(), pid)
      send(pid, :go)

      assert_receive {:ok, "allowed"}
    end

    test "options are checked even when a stub would answer" do
      URP.Test.stub(fn _input, _opts -> flunk("invalid calls must not reach the stub") end)

      for {opts, message} <- [
            {[output: :binary], ~r/required :filter option/},
            {[filter: @pdf], ~r/required :output option/},
            {[filter: @pdf, output: :binary, io: :stream], ~r/unknown options \[:io\]/},
            {[filter: @pdf, output: {:invalid, :output}], ~r/invalid value for :output option/},
            {[filter: @pdf, output: :binary, pool: "name"], ~r/invalid value for :pool option/}
          ] do
        assert_raise NimbleOptions.ValidationError, message, fn ->
          URP.convert({:binary, "bytes"}, opts)
        end
      end
    end

    test "convert!/2 returns the result, and raises by the kind of failure" do
      opts = [filter: @pdf, output: :binary]

      URP.Test.stub(fn _input, _opts -> {:ok, "bytes"} end)
      assert URP.convert!({:binary, "b"}, opts) == "bytes"

      URP.Test.stub(fn _input, _opts -> {:error, "soffice refused"} end)
      assert_raise URP.Error, "soffice refused", fn -> URP.convert!({:binary, "b"}, opts) end

      URP.Test.stub(fn _input, _opts -> {:error, :closed} end)
      assert_raise URP.SocketError, fn -> URP.convert!({:binary, "b"}, opts) end
    end

    test "a pool that is not configured is an error" do
      assert_raise ArgumentError, ~r/pool :nowhere is not configured/, fn ->
        URP.version(pool: :nowhere)
      end
    end
  end
end

defmodule URP.DocTest do
  use ExUnit.Case, async: true
  doctest URP
  doctest URP.Test
end
