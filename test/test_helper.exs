soffice_available? =
  case :gen_tcp.connect(~c"localhost", 2002, [:binary], 1000) do
    {:ok, sock} ->
      :gen_tcp.close(sock)
      true

    {:error, _} ->
      false
  end

# Tests tagged :lo26 require LibreOffice 26.2+. Excluded by default for
# local development with older soffice. CI includes them (--include lo26).
excluded_tags = if soffice_available?, do: [:lo26], else: [:integration, :lo26]

unless soffice_available? do
  IO.puts("soffice not reachable on localhost:2002 — excluding integration tests")
end

ExUnit.start(exclude: excluded_tags)
