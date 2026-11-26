defmodule URP.BridgeDrainTest do
  use ExUnit.Case, async: true

  alias URP.Bridge
  alias URP.Protocol, as: P

  defp socket_pair do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    {:ok, client} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])
    {:ok, server} = :gen_tcp.accept(listen, 1_000)
    :gen_tcp.close(listen)

    on_exit(fn ->
      :gen_tcp.close(client)
      :gen_tcp.close(server)
    end)

    {client, server}
  end

  defp abandoned(client) do
    %Bridge{sock: client, error: :timeout, pending: :reply, recv_timeout: 10}
  end

  describe inspect(&Bridge.cleanup/2) do
    test "sends nothing while a reply is outstanding" do
      {client, server} = socket_pair()
      conn = %{abandoned(client) | doc_oid: "doc", cleanup_url: "file:///tmp/urp_in_x"}

      assert %Bridge{doc_oid: "doc", cleanup_url: "file:///tmp/urp_in_x", pending: :reply} =
               Bridge.cleanup(conn)

      assert :gen_tcp.recv(server, 0, 50) == {:error, :timeout}
    end
  end

  describe inspect(&Bridge.drain/2) do
    test "returns a connection that owes nothing as it is" do
      conn = %Bridge{error: "soffice refused the document"}

      assert Bridge.drain(conn, 1_000) == conn
    end

    test "waits for the reply the caller stopped waiting for" do
      {client, server} = socket_pair()

      Task.start(fn ->
        Process.sleep(50)
        P.send_frame(server, P.reply())
      end)

      assert %Bridge{error: nil, pending: nil} = Bridge.drain(abandoned(client), 2_000)
    end

    test "gives up when the reply never comes" do
      {client, _server} = socket_pair()

      assert %Bridge{error: :timeout, pending: nil} = Bridge.drain(abandoned(client), 0)
    end
  end
end
