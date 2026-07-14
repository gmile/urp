defmodule URP.Telemetry do
  @moduledoc """
  Telemetry events emitted by URP.

  ## Events

  ### `[:urp, :call, :start]`

  Emitted before requesting a connection from the pool. Measurements contain
  `:system_time`; metadata contains `:operation` and `:pool`.

  ### `[:urp, :call, :stop]`

  Emitted when an operation completes normally, including operations that
  return an error tuple.

  #### Measurements (in `:native` time units)

  | Key | Description |
  |---|---|
  | `:total_time` | Wall time from checkout request to work completion |
  | `:queue_time` | Time spent waiting for a pool connection |
  | `:service_time` | Time spent doing work on the connection |
  | `:backoff_time` | Time spent outside queue/service, primarily disposed-bridge retry backoff |

  Use `System.convert_time_unit/3` to convert to milliseconds or
  microseconds:

      System.convert_time_unit(queue_time, :native, :millisecond)

  #### Metadata

  | Key | Type | Description |
  |---|---|---|
  | `:operation` | `atom` | The operation performed (e.g. `:convert`, `:version`, `:filters`) |
  | `:pool` | `term` | The pool name or pid |
  | `:result` | `:ok \\| :error` | Whether the operation succeeded |
  | `:attempts` | `pos_integer` | Number of checkout attempts |

  ### `[:urp, :call, :exception]`

  Emitted when checkout exits or operation code raises, throws, or exits.
  Measurements contain `:duration`. Metadata contains `:operation`, `:pool`,
  `:kind`, `:reason`, and `:stacktrace`. Expected pool exits are converted into
  `{:error, message}` by non-bang APIs after this event is emitted.

  ### `[:urp, :connection, :retry]`

  Emitted when a worker cannot connect to soffice and schedules another
  attempt. Measurements contain `:attempt` and `:delay` in milliseconds.
  Metadata contains `:host`, `:port`, and `:reason`.

  ## Example handler

      :telemetry.attach(
        "urp-logger",
        [:urp, :call, :stop],
        fn event, measurements, metadata, _config ->
          total_ms = System.convert_time_unit(measurements.total_time, :native, :millisecond)
          queue_ms = System.convert_time_unit(measurements.queue_time, :native, :millisecond)

          Logger.info(
            "[URP] \#{metadata.operation} \#{metadata.result} " <>
              "total=\#{total_ms}ms queue=\#{queue_ms}ms"
          )
        end,
        nil
      )
  """
end
