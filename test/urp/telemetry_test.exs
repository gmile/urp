defmodule URP.TelemetryTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 15_000

  @handler_id "telemetry-test-handler"

  def handle_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  setup do
    :telemetry.attach(@handler_id, [:urp, :call, :stop], &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(@handler_id) end)
  end

  test "emits [:urp, :call, :stop] with measurements and metadata" do
    assert {:ok, _version} = URP.version()

    assert_receive {:telemetry_event, [:urp, :call, :stop], measurements, metadata}

    assert is_integer(measurements.total_time)
    assert is_integer(measurements.queue_time)
    assert is_integer(measurements.service_time)
    assert measurements.total_time > 0
    assert measurements.queue_time >= 0
    assert measurements.service_time > 0
    assert measurements.total_time == measurements.queue_time + measurements.service_time

    assert metadata.operation == :version
    assert metadata.pool == URP.Pool.Default
    assert metadata.result == :ok
  end

  test "reports :convert operation" do
    docx = build_test_docx()

    assert {:ok, _pdf} =
             URP.convert({:binary, docx}, filter: "writer_pdf_Export", output: :binary)

    assert_receive {:telemetry_event, [:urp, :call, :stop], _measurements, metadata}
    assert metadata.operation == :convert
    assert metadata.result == :ok
  end

  test "reports :error result on failure" do
    assert {:error, _} =
             URP.convert("/tmp/nonexistent_#{System.unique_integer([:positive])}.docx",
               filter: "writer_pdf_Export",
               output: :binary
             )

    assert_receive {:telemetry_event, [:urp, :call, :stop], _measurements, metadata}
    assert metadata.result == :error
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
        <w:p><w:r><w:t>Hello from telemetry test</w:t></w:r></w:p>
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
