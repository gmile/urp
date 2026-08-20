defmodule URP.SocketError do
  @moduledoc """
  Raised when the socket to `soffice` fails during a call.

  `reason` is the atom `:gen_tcp` reported — `:timeout`, `:closed`, or a POSIX
  error. Conversion functions return that atom as-is, so a caller can tell a
  `soffice` that stopped answering from a document it refused, which arrives as
  a message string.
  """

  defexception [:reason, :message]

  @type t :: %__MODULE__{reason: :timeout | :closed | :inet.posix(), message: String.t()}

  @impl true
  @spec exception(keyword()) :: t()
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)

    %__MODULE__{reason: reason, message: describe(reason)}
  end

  @spec describe(atom()) :: String.t()
  defp describe(:timeout), do: "soffice did not answer in time"
  defp describe(:closed), do: "soffice closed the connection"
  defp describe(reason), do: "socket failed: #{:inet.format_error(reason)}"
end
