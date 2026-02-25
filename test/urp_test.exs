defmodule URPTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 30_000

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

  describe "URP.Connection" do
    setup do
      pid = start_supervised!({URP.Connection, name: :test_conn})
      {:ok, conn: pid}
    end

    test "converts via GenServer" do
      docx_bytes = build_test_docx()
      assert {:ok, pdf} = URP.Connection.convert_stream(:test_conn, docx_bytes)
      assert <<"%PDF-" <> _rest>> = pdf
    end

    test "converts file-backed via GenServer" do
      id = System.unique_integer([:positive])
      input = Path.join(@test_dir, "urp_test_#{id}.docx")
      create_test_docx!(input)

      try do
        assert {:ok, pdf} = URP.Connection.convert_file_stream(:test_conn, input)
        assert <<"%PDF-" <> _rest>> = pdf
      after
        File.rm(input)
      end
    end
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
