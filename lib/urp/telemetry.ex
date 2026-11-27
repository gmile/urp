defmodule URP.Telemetry do
  @moduledoc """
  Telemetry events emitted by URP.

  ## Events

  The three `[:urp, :call, _]` events are a `:telemetry.span/3` around one
  operation, from asking the pool for a connection to having the result.
  Times are in `:native` units; `System.convert_time_unit/3` converts them.

  ### `[:urp, :call, :start]`

  Measurements contain `:system_time` and `:monotonic_time`; metadata contains
  `:operation` (such as `:convert` or `:version`) and `:pool`.

  ### `[:urp, :call, :stop]`

  Emitted when an operation completes, including one that returns an error
  tuple.

  | Measurement | Description |
  |---|---|
  | `:duration` | From asking for a connection to having the result |
  | `:queue_time` | Time spent waiting for a connection to take the job |
  | `:service_time` | Time the connection spent on it |

  A call that timed out reports only `:duration`: the caller cannot know how
  far it got. Metadata adds `:result`, `:ok` or `:error`, to that of the start
  event.

  ### `[:urp, :call, :exception]`

  Emitted if the operation raises in the caller. Measurements contain
  `:duration`. Metadata adds `:kind`, `:reason` and `:stacktrace`.

  ### `[:urp, :connection, :retry]`

  Emitted when a connection cannot connect to soffice and will try again.
  Measurements contain `:attempt` and `:delay` in milliseconds. Metadata
  contains `:host`, `:address`, `:port` and `:reason`.

  ### `[:urp, :connection, :drain]`

  Emitted when a connection is done with a job whose caller had stopped
  waiting. Measurements contain `:duration`, the time since the caller's
  `:timeout` ran out, in `:native` units. Metadata contains `:host`,
  `:address`, `:port` and `:result`: `:ok` when what the job left behind was
  released and the connection takes its next job, or `{:error, reason}` when
  the connection was lost and reconnects — `{:error, :timeout}` if `soffice`
  said nothing for the whole `:drain_timeout`.

  ## Example handler

      :telemetry.attach(
        "urp-logger",
        [:urp, :call, :stop],
        fn _event, %{duration: duration}, metadata, _config ->
          ms = System.convert_time_unit(duration, :native, :millisecond)
          Logger.info("[URP] \#{metadata.operation} \#{metadata.result} in \#{ms}ms")
        end,
        nil
      )
  """
end
