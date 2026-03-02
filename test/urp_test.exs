defmodule URPTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 15_000

  # Use /tmp (not System.tmp_dir!) so paths match inside the soffice Docker container
  @test_dir "/tmp"
  @pdf "writer_pdf_Export"

  describe "file path input" do
    test "default output (temp file)" do
      input = write_test_file!("txt", "Hello from URP test")

      try do
        assert {:ok, tmp_path} = URP.convert(input, filter: @pdf)
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
        assert {:ok, ^output} = URP.convert(input, filter: @pdf, output: output)
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
        assert {:ok, pdf} = URP.convert(input, filter: @pdf, output: :binary)
        assert <<"%PDF-" <> _rest>> = pdf
      after
        File.rm(input)
      end
    end

    test "output: fun/1 callback" do
      input = write_test_file!("docx", build_test_docx())
      test_pid = self()

      try do
        assert :ok =
                 URP.convert(input,
                   filter: @pdf,
                   output: fn chunk -> send(test_pid, {:chunk, chunk}) end
                 )

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
      assert {:ok, pdf} = URP.convert({:binary, build_test_docx()}, filter: @pdf, output: :binary)
      assert <<"%PDF-" <> _rest>> = pdf
    end

    test "default output (temp file)" do
      assert {:ok, tmp_path} = URP.convert({:binary, build_test_docx()}, filter: @pdf)
      assert String.ends_with?(tmp_path, ".pdf")
      assert <<"%PDF-" <> _rest>> = File.read!(tmp_path)
    end
  end

  describe "enumerable input" do
    test "default output (temp file)" do
      chunks = to_chunks(build_test_docx(), 512)
      assert {:ok, tmp_path} = URP.convert(chunks, filter: @pdf)
      assert String.ends_with?(tmp_path, ".pdf")
      assert <<"%PDF-" <> _rest>> = File.read!(tmp_path)
    end

    test "output: :binary" do
      chunks = to_chunks(build_test_docx(), 512)
      assert {:ok, pdf} = URP.convert(chunks, filter: @pdf, output: :binary)
      assert <<"%PDF-" <> _rest>> = pdf
    end
  end

  describe "filters" do
    test "xlsx to pdf via calc_pdf_Export" do
      assert {:ok, pdf} =
               URP.convert({:binary, build_test_xlsx()},
                 filter: "calc_pdf_Export",
                 output: :binary
               )

      assert <<"%PDF-" <> _rest>> = pdf
    end

    # Markdown export requires LibreOffice 26.2+ (confirmed working on macOS 26.2.1.2).
    # Alpine edge still ships 25.8 — unskip once Docker image catches up.
    @tag :skip
    test "docx to markdown" do
      assert {:ok, md} =
               URP.convert({:binary, build_test_docx()},
                 filter: "Markdown",
                 output: :binary
               )

      assert md =~ "Hello from URP smoke test"
    end
  end

  describe "real-world fixtures" do
    # These tests convert non-trivial documents from filesamples.com and verify
    # the PDF output has the expected page count — catching regressions like
    # empty-page output from missing XSeekable or broken TID caching.

    test "sample3.docx produces multi-page PDF" do
      docx = File.read!("test/fixtures/sample3.docx")

      assert {:ok, pdf} = URP.convert({:binary, docx}, filter: @pdf, output: :binary)
      assert <<"%PDF-" <> _>> = pdf
      assert pdf_page_count(pdf) >= 4
    end

    test "sample1.xlsx produces multi-page PDF" do
      xlsx = File.read!("test/fixtures/sample1.xlsx")

      assert {:ok, pdf} =
               URP.convert({:binary, xlsx}, filter: "calc_pdf_Export", output: :binary)

      assert <<"%PDF-" <> _>> = pdf
      assert pdf_page_count(pdf) >= 9
    end
  end

  describe "filter_data" do
    test "PDF export with filter options" do
      assert {:ok, pdf} =
               URP.convert({:binary, build_test_docx()},
                 filter: @pdf,
                 filter_data: [UseLosslessCompression: true, ExportFormFields: false],
                 output: :binary
               )

      assert <<"%PDF-" <> _>> = pdf
    end

    test "integer filter option (FormsType)" do
      assert {:ok, pdf} =
               URP.convert({:binary, build_test_docx()},
                 filter: @pdf,
                 filter_data: [FormsType: 0],
                 output: :binary
               )

      assert <<"%PDF-" <> _>> = pdf
    end

    test "pool stays usable after filter_data conversion" do
      assert {:ok, _} =
               URP.convert({:binary, build_test_docx()},
                 filter: @pdf,
                 filter_data: [UseLosslessCompression: true],
                 output: :binary
               )

      assert {:ok, pdf} = URP.convert({:binary, build_test_docx()}, filter: @pdf, output: :binary)
      assert <<"%PDF-" <> _>> = pdf
    end
  end

  describe "temp file cleanup" do
    test "no urp_in temp files linger after conversion" do
      assert {:ok, _pdf} =
               URP.convert({:binary, build_test_docx()}, filter: @pdf, output: :binary)

      assert Enum.empty?(Path.wildcard("/tmp/urp_in_*"))
    end

    test "no urp_out temp files linger after conversion" do
      assert {:ok, _pdf} =
               URP.convert({:binary, build_test_docx()}, filter: @pdf, output: :binary)

      assert Enum.empty?(Path.wildcard("/tmp/urp_out_*"))
    end
  end

  describe "error handling" do
    test "nonexistent file returns error" do
      assert {:error, _message} =
               URP.convert("/tmp/nonexistent_#{System.unique_integer([:positive])}.docx",
                 filter: @pdf,
                 output: :binary
               )
    end

    test "pool stays alive after error" do
      assert {:error, _} =
               URP.convert(
                 "/tmp/nonexistent_#{System.unique_integer([:positive])}.docx",
                 filter: @pdf,
                 output: :binary
               )

      assert {:ok, pdf} = URP.convert({:binary, build_test_docx()}, filter: @pdf, output: :binary)
      assert <<"%PDF-" <> _rest>> = pdf
    end
  end

  describe "version/0" do
    test "returns a version string" do
      assert {:ok, version} = URP.version()
      assert version =~ ~r/^\d+\.\d+\.\d+/
    end

    test "pool stays usable after version query" do
      assert {:ok, _version} = URP.version()
      assert {:ok, pdf} = URP.convert({:binary, build_test_docx()}, filter: @pdf, output: :binary)
      assert <<"%PDF-" <> _rest>> = pdf
    end
  end

  describe "consecutive conversions" do
    test "multiple conversions reuse pool" do
      docx = build_test_docx()
      assert {:ok, pdf1} = URP.convert({:binary, docx}, filter: @pdf, output: :binary)
      assert {:ok, pdf2} = URP.convert({:binary, docx}, filter: @pdf, output: :binary)
      assert <<"%PDF-" <> _rest>> = pdf1
      assert <<"%PDF-" <> _rest>> = pdf2
    end
  end

  describe "URP.Test stubs" do
    @describetag integration: false

    test "stub receives opts" do
      URP.Test.stub(fn _input, opts ->
        assert opts[:filter] == "calc_pdf_Export"
        assert opts[:output] == :binary
        {:ok, "filtered"}
      end)

      assert {:ok, "filtered"} =
               URP.convert({:binary, "bytes"}, filter: "calc_pdf_Export", output: :binary)
    end

    test "stub is per-process via $callers" do
      URP.Test.stub(fn _input, _opts -> {:ok, "parent stub"} end)

      task =
        Task.async(fn ->
          URP.convert({:binary, "bytes"}, filter: @pdf, output: :binary)
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

  # Extract page count from the PDF Pages dictionary (/Type /Pages ... /Count N).
  # Returns 0 if parsing fails.
  defp pdf_page_count(pdf) when is_binary(pdf) do
    case Regex.run(~r|/Type\s*/Pages.*?/Count\s+(\d+)|s, pdf) do
      [_, count] -> String.to_integer(count)
      nil -> 0
    end
  end

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

  defp build_test_xlsx do
    content_types = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml"
        ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/worksheets/sheet1.xml"
        ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    </Types>
    """

    rels = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1"
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
        Target="xl/workbook.xml"/>
    </Relationships>
    """

    workbook_rels = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1"
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"
        Target="worksheets/sheet1.xml"/>
    </Relationships>
    """

    workbook = """
    <?xml version="1.0" encoding="UTF-8"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
              xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
    </workbook>
    """

    sheet = """
    <?xml version="1.0" encoding="UTF-8"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <sheetData>
        <row r="1"><c r="A1" t="inlineStr"><is><t>Hello</t></is></c></row>
      </sheetData>
    </worksheet>
    """

    {:ok, {_, zip_binary}} =
      :zip.create(
        ~c"test.xlsx",
        [
          {~c"[Content_Types].xml", String.trim(content_types)},
          {~c"_rels/.rels", String.trim(rels)},
          {~c"xl/_rels/workbook.xml.rels", String.trim(workbook_rels)},
          {~c"xl/workbook.xml", String.trim(workbook)},
          {~c"xl/worksheets/sheet1.xml", String.trim(sheet)}
        ],
        [:memory]
      )

    zip_binary
  end
end

defmodule URP.DocTest do
  use ExUnit.Case, async: true
  doctest URP
  doctest URP.Test
end
