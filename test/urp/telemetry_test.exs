defmodule URP.TelemetryTest do
  use ExUnit.Case, async: false

  import URP.TestFixtures

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

    assert measurements.duration > 0
    assert measurements.queue_time >= 0
    assert measurements.service_time > 0
    assert measurements.duration >= measurements.queue_time + measurements.service_time

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
end
