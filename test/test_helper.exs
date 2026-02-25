soffice_available? =
  case :gen_tcp.connect(~c"localhost", 2002, [:binary], 1000) do
    {:ok, sock} ->
      :gen_tcp.close(sock)
      true

    {:error, _} ->
      IO.puts("soffice not reachable on localhost:2002 — skipping integration tests")
      false
  end

exclude = if soffice_available?, do: [], else: [:integration]
ExUnit.start(exclude: exclude)
