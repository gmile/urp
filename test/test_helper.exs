integration? = System.get_env("URP_INTEGRATION") in ["1", "true"]

excluded_tags =
  if integration? do
    {:ok, _apps} = Application.ensure_all_started(:urp)

    version =
      case URP.version(timeout: 10_000) do
        {:ok, version} ->
          version

        {:error, message} ->
          raise "URP_INTEGRATION is enabled but soffice is unavailable: #{message}"
      end

    lo26? =
      case Regex.run(~r/^(\d+)\.(\d+)/, version) do
        [_, major, minor] ->
          {major, minor} = {String.to_integer(major), String.to_integer(minor)}
          major > 26 or (major == 26 and minor >= 2)

        _other ->
          false
      end

    IO.puts("running integration tests against LibreOffice #{version}")
    if lo26?, do: [], else: [:lo26]
  else
    IO.puts("URP_INTEGRATION is not enabled — excluding integration tests")
    [:integration, :lo26]
  end

ExUnit.start(exclude: excluded_tags)
