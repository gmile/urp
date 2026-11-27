defmodule URP.SocketError do
  @moduledoc """
  Raised by the functions ending in `!` when there was no answer to be had.

  `reason` is the atom the non-raising function returns: `:timeout`, `:closed`,
  `:unavailable`, `:protocol_error` or a POSIX error from the socket.
  """

  defexception [:reason, :message]

  @type t :: %__MODULE__{reason: atom(), message: String.t()}

  @impl true
  @spec exception(keyword()) :: t()
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)

    %__MODULE__{reason: reason, message: describe(reason)}
  end

  @spec describe(atom()) :: String.t()
  defp describe(:timeout), do: "soffice did not answer in time"
  defp describe(:closed), do: "soffice closed the connection"
  defp describe(:unavailable), do: "the pool is not running"
  defp describe(:protocol_error), do: "the exchange with soffice went wrong; see the log"
  defp describe(reason), do: "socket failed: #{:inet.format_error(reason)}"
end
