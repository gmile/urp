defmodule URPTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 15_000

  # Use /tmp (not System.tmp_dir!) so paths match inside the soffice Docker container
  @test_dir "/tmp"

  describe "file path input" do
    test "default output (temp file)" do
      input = write_test_file!("txt", "Hello from URP test")

      try do
        assert {:ok, tmp_path} = URP.convert(input)
        assert String.ends_with?(tmp_path, ".pdf")
        assert <<"%PDF-" <> _rest>> = File.read!(tmp_path)
      after
        File.rm(input)
      end
    end

    test "output: explicit path" do
      input = write_test_file!("txt", "Hello from URP test")
      output = tmp_path("pdf")

      try do
        assert {:ok, ^output} = URP.convert(input, output: output)
        assert File.exists?(output)
        assert <<"%PDF-" <> _rest>> = File.read!(output)
      after
        File.rm(input)
        File.rm(output)
      end
    end

    test "output: :binary" do
      input = write_test_file!("docx", build_test_docx())

      try do
        assert {:ok, pdf} = URP.convert(input, output: :binary)
        assert <<"%PDF-" <> _rest>> = pdf
      after
        File.rm(input)
      end
    end

    test "output: fun/1 callback" do
      input = write_test_file!("docx", build_test_docx())
      test_pid = self()

      try do
        assert :ok = URP.convert(input, output: fn chunk -> send(test_pid, {:chunk, chunk}) end)
        chunks = collect_chunks()
        pdf = IO.iodata_to_binary(chunks)
        assert <<"%PDF-" <> _rest>> = pdf
      after
        File.rm(input)
      end
    end
  end

  describe "{:binary, bytes} input" do
    test "output: :binary" do
      assert {:ok, pdf} = URP.convert({:binary, build_test_docx()}, output: :binary)
      assert <<"%PDF-" <> _rest>> = pdf
    end

    test "default output (temp file)" do
      assert {:ok, tmp_path} = URP.convert({:binary, build_test_docx()})
      assert String.ends_with?(tmp_path, ".pdf")
      assert <<"%PDF-" <> _rest>> = File.read!(tmp_path)
    end
  end

  describe "enumerable input" do
    test "default output (temp file)" do
      chunks = to_chunks(build_test_docx(), 512)
      assert {:ok, tmp_path} = URP.convert(chunks)
      assert String.ends_with?(tmp_path, ".pdf")
      assert <<"%PDF-" <> _rest>> = File.read!(tmp_path)
    end

    test "output: :binary" do
      chunks = to_chunks(build_test_docx(), 512)
      assert {:ok, pdf} = URP.convert(chunks, output: :binary)
      assert <<"%PDF-" <> _rest>> = pdf
    end
  end

  describe "error handling" do
    test "nonexistent file returns error" do
      assert {:error, _message} =
               URP.convert("/tmp/nonexistent_#{System.unique_integer([:positive])}.docx",
                 output: :binary
               )
    end

    test "pool stays alive after error" do
      assert {:error, _} =
               URP.convert(
                 "/tmp/nonexistent_#{System.unique_integer([:positive])}.docx",
                 output: :binary
               )

      assert {:ok, pdf} = URP.convert({:binary, build_test_docx()}, output: :binary)
      assert <<"%PDF-" <> _rest>> = pdf
    end
  end

  describe "consecutive conversions" do
    test "multiple conversions reuse pool" do
      docx = build_test_docx()
      assert {:ok, pdf1} = URP.convert({:binary, docx}, output: :binary)
      assert {:ok, pdf2} = URP.convert({:binary, docx}, output: :binary)
      assert <<"%PDF-" <> _rest>> = pdf1
      assert <<"%PDF-" <> _rest>> = pdf2
    end
  end

  describe "URP.Test stubs" do
    @describetag integration: false

    test "stub bypasses real conversion" do
      URP.Test.stub(fn input, _opts ->
        assert input == "/tmp/test.docx"
        {:ok, "/tmp/test.pdf"}
      end)

      assert {:ok, "/tmp/test.pdf"} = URP.convert("/tmp/test.docx", output: "/tmp/test.pdf")
    end

    test "stub with {:binary, bytes} input" do
      URP.Test.stub(fn {:binary, bytes}, _opts ->
        assert bytes == "hello"
        {:ok, "fake PDF"}
      end)

      assert {:ok, "fake PDF"} = URP.convert({:binary, "hello"}, output: :binary)
    end

    test "stub receives opts" do
      URP.Test.stub(fn _input, opts ->
        assert opts[:filter] == "calc_pdf_Export"
        assert opts[:output] == :binary
        {:ok, "filtered"}
      end)

      assert {:ok, "filtered"} =
               URP.convert({:binary, "bytes"}, output: :binary, filter: "calc_pdf_Export")
    end

    test "stub is per-process via $callers" do
      URP.Test.stub(fn _input, _opts -> {:ok, "parent stub"} end)

      task =
        Task.async(fn ->
          URP.convert({:binary, "bytes"}, output: :binary)
        end)

      assert {:ok, "parent stub"} = Task.await(task)
    end
  end

  defp collect_chunks(acc \\ []) do
    receive do
      {:chunk, chunk} -> collect_chunks([chunk | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp to_chunks(binary, chunk_size) do
    binary
    |> Stream.unfold(fn
      <<>> -> nil
      bin -> String.split_at(bin, chunk_size)
    end)
  end

  defp tmp_path(ext) do
    id = System.unique_integer([:positive])
    Path.join(@test_dir, "urp_test_#{id}.#{ext}")
  end

  defp write_test_file!(ext, content) do
    path = tmp_path(ext)
    File.write!(path, content)
    path
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
