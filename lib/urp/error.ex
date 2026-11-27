defmodule URP.Error do
  @moduledoc """
  Raised by the functions ending in `!` when a job fails for a reason of its
  own: `soffice` would not load or export the document, the input could not be
  read, the output could not be written.
  """

  defexception [:message]
end
