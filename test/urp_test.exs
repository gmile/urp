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
      :zip.create(~c"test.docx", [
        {~c"[Content_Types].xml", String.trim(content_types)},
        {~c"_rels/.rels", String.trim(rels)},
        {~c"word/document.xml", String.trim(document)}
      ], [:memory])

    zip_binary
  end
end
