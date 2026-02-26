defmodule URPTest.StubConverter do
  use URP, otp_app: :urp
end

defmodule URPTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 15_000

  # Use /tmp (not System.tmp_dir!) so paths match inside the soffice Docker container
  @test_dir "/tmp"

  test "converts docx to pdf" do
    id = System.unique_integer([:positive])
    input = Path.join(@test_dir, "urp_test_#{id}.docx")
    output = Path.join(@test_dir, "urp_test_#{id}.pdf")
    create_test_docx!(input)

    try do
      assert {:ok, ^output} = URP.convert(input, output)
      assert File.exists?(output)
      assert <<"%PDF-" <> _rest>> = File.read!(output)
    after
      File.rm(input)
      File.rm(output)
    end
  end

  test "converts txt to pdf" do
    id = System.unique_integer([:positive])
    input = Path.join(@test_dir, "urp_test_#{id}.txt")
    output = Path.join(@test_dir, "urp_test_#{id}.pdf")

    File.write!(input, "Hello from URP test")

    try do
      assert {:ok, ^output} = URP.convert(input, output)
      assert File.exists?(output)
      assert <<"%PDF-" <> _rest>> = File.read!(output)
    after
      File.rm(input)
      File.rm(output)
    end
  end

  test "infers output path from input" do
    id = System.unique_integer([:positive])
    input = Path.join(@test_dir, "urp_test_#{id}.txt")
    expected_output = Path.join(@test_dir, "urp_test_#{id}.pdf")

    File.write!(input, "Hello from URP test")

    try do
      assert {:ok, ^expected_output} = URP.convert(input)
      assert File.exists?(expected_output)
    after
      File.rm(input)
      File.rm(expected_output)
    end
  end

  test "converts docx to pdf via streaming" do
    docx_bytes = build_test_docx()
    assert {:ok, pdf} = URP.convert_stream(docx_bytes)
    assert <<"%PDF-" <> _rest>> = pdf
  end

  test "converts txt to pdf via streaming" do
    assert {:ok, pdf} = URP.convert_stream("Hello from streaming test")
    assert <<"%PDF-" <> _rest>> = pdf
  end


  describe "sink" do
    test "sink: {:path, ...} writes to file" do
      id = System.unique_integer([:positive])
      output = Path.join(@test_dir, "urp_sink_#{id}.pdf")

      try do
        assert :ok = URP.convert_stream(build_test_docx(), sink: {:path, output})
        assert <<"%PDF-" <> _rest>> = File.read!(output)
      after
        File.rm(output)
      end
    end

    test "sink: fun/1 receives chunks" do
      test_pid = self()

      :ok =
        URP.convert_stream(build_test_docx(),
          sink: fn chunk -> send(test_pid, {:chunk, chunk}) end
        )

      chunks = collect_chunks()
      pdf = IO.iodata_to_binary(chunks)
      assert <<"%PDF-" <> _rest>> = pdf
    end
  end

  describe "URP.Pool" do
    setup do
      pid = start_supervised!({URP.Pool, name: :test_pool, pool_size: 2})
      {:ok, pool: pid}
    end

    test "converts via pool" do
      docx_bytes = build_test_docx()
      assert {:ok, pdf} = URP.Pool.convert_stream(:test_pool, docx_bytes)
      assert <<"%PDF-" <> _rest>> = pdf
    end

    test "converts file-backed via pool" do
      id = System.unique_integer([:positive])
      input = Path.join(@test_dir, "urp_test_#{id}.docx")
      create_test_docx!(input)

      try do
        assert {:ok, pdf} = URP.Pool.convert_file_stream(:test_pool, input)
        assert <<"%PDF-" <> _rest>> = pdf
      after
        File.rm(input)
      end
    end

    test "handles consecutive streaming conversions" do
      docx_bytes = build_test_docx()
      assert {:ok, pdf1} = URP.Pool.convert_stream(:test_pool, docx_bytes)
      assert {:ok, pdf2} = URP.Pool.convert_stream(:test_pool, docx_bytes)
      assert <<"%PDF-" <> _rest>> = pdf1
      assert <<"%PDF-" <> _rest>> = pdf2
    end
  end

  test "converts docx file to pdf via file-backed streaming" do
    id = System.unique_integer([:positive])
    input = Path.join(@test_dir, "urp_test_#{id}.docx")
    create_test_docx!(input)

    try do
      assert {:ok, pdf} = URP.convert_file_stream(input)
      assert <<"%PDF-" <> _rest>> = pdf
    after
      File.rm(input)
    end
  end

  describe "error handling" do
    test "convert_file_stream with nonexistent file raises" do
      assert_raise File.Error, fn ->
        URP.convert_file_stream("/tmp/nonexistent_#{System.unique_integer([:positive])}.docx")
      end
    end

    test "convert with nonexistent file raises" do
      id = System.unique_integer([:positive])

      assert_raise RuntimeError, ~r/loadComponentFromURL failed/, fn ->
        URP.convert("/tmp/nonexistent_#{id}.docx", "/tmp/nonexistent_#{id}.pdf")
      end
    end

    test "pool returns error for nonexistent file" do
      _pid = start_supervised!({URP.Pool, name: :error_pool, pool_size: 1})
      id = System.unique_integer([:positive])

      assert {:error, _message} =
               URP.Pool.convert_file_stream(:error_pool, "/tmp/nonexistent_#{id}.docx")
    end

    test "pool returns {:error, _} and stays alive after error" do
      _pid = start_supervised!({URP.Pool, name: :error_pool2, pool_size: 1})
      id = System.unique_integer([:positive])

      assert {:error, _} =
               URP.Pool.convert_file_stream(:error_pool2, "/tmp/nonexistent_#{id}.docx")

      # Pool process should still be alive (not crashed)
      assert Process.whereis(:error_pool2) != nil
    end
  end

  describe "URP.Test" do
    test "stub bypasses real conversion" do
      URP.Test.stub(URPTest.StubConverter, fn input, _opts ->
        assert input == "hello"
        {:ok, "fake PDF"}
      end)

      assert {:ok, "fake PDF"} = URPTest.StubConverter.convert_stream("hello")
    end

    test "stub works with convert_file_stream" do
      URP.Test.stub(URPTest.StubConverter, fn input, _opts ->
        assert input == "/tmp/test.docx"
        {:ok, "fake PDF"}
      end)

      assert {:ok, "fake PDF"} = URPTest.StubConverter.convert_file_stream("/tmp/test.docx")
    end

    test "stub receives opts" do
      URP.Test.stub(URPTest.StubConverter, fn _input, opts ->
        assert opts[:filter] == "calc_pdf_Export"
        {:ok, "filtered"}
      end)

      assert {:ok, "filtered"} =
               URPTest.StubConverter.convert_stream("bytes", filter: "calc_pdf_Export")
    end

    test "stub is per-process via $callers" do
      URP.Test.stub(URPTest.StubConverter, fn _input, _opts -> {:ok, "parent stub"} end)

      task =
        Task.async(fn ->
          URPTest.StubConverter.convert_stream("bytes")
        end)

      assert {:ok, "parent stub"} = Task.await(task)
    end

    test "without stub, delegates to pool" do
      # No stub registered — routes through Pool. Start one for this test.
      start_supervised!({URP.Pool, name: URPTest.StubConverter})
      assert {:ok, pdf} = URPTest.StubConverter.convert_stream(build_test_docx())
      assert <<"%PDF-" <> _rest>> = pdf
    end
  end

  defp collect_chunks(acc \\ []) do
    receive do
      {:chunk, chunk} -> collect_chunks([chunk | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp create_test_docx!(path) do
    File.write!(path, build_test_docx())
  end

  # Build a minimal .docx (Office Open XML) in memory using :zip
  defp build_test_docx do
    content_types = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/word/document.xml"
        ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """

    rels = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1"
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
        Target="word/document.xml"/>
    </Relationships>
    """

    document = """
    <?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p><w:r><w:t>Hello from URP smoke test</w:t></w:r></w:p>
      </w:body>
    </w:document>
    """

    {:ok, {_, zip_binary}} =
      :zip.create(
        ~c"test.docx",
        [
          {~c"[Content_Types].xml", String.trim(content_types)},
          {~c"_rels/.rels", String.trim(rels)},
          {~c"word/document.xml", String.trim(document)}
        ],
        [:memory]
      )

    zip_binary
  end
end
