case :gen_tcp.connect(~c"localhost", 2002, [:binary], 1000) do
  {:ok, sock} ->
    :gen_tcp.close(sock)

  {:error, _} ->
    raise "soffice not reachable on localhost:2002 — start it before running tests"
end

URP.Test.start()
ExUnit.start()
