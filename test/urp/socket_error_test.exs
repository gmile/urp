defmodule URP.SocketErrorTest do
  use ExUnit.Case, async: true

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

  describe inspect(&P.recv_frame/3) do
    test "returns the payload of a well-formed block" do
      {client, server} = socket_pair()
      payload = "a reply"

      :ok = :gen_tcp.send(server, [<<byte_size(payload)::32, 1::32>>, payload])

      assert P.recv_frame(client, 1_000) == payload
    end

    test "raises with reason :timeout when soffice stops answering" do
      {client, _server} = socket_pair()

      assert_raise URP.SocketError, "soffice did not answer in time", fn ->
        P.recv_frame(client, 10)
      end
    end

    test "carries the reason as an atom rather than a formatted message" do
      {client, _server} = socket_pair()

      assert %URP.SocketError{reason: :timeout} =
               assert_raise(URP.SocketError, fn -> P.recv_frame(client, 10) end)
    end

    test "raises with reason :closed when soffice hangs up" do
      {client, server} = socket_pair()
      :gen_tcp.close(server)

      assert %URP.SocketError{reason: :closed} =
               assert_raise(URP.SocketError, fn -> P.recv_frame(client, 1_000) end)
    end

    test "raises with reason :closed while reading the body of an announced frame" do
      {client, server} = socket_pair()

      # Announce 64 bytes, deliver 4, then hang up.
      :ok = :gen_tcp.send(server, [<<64::32, 1::32>>, "abcd"])
      :gen_tcp.close(server)

      assert %URP.SocketError{reason: :closed} =
               assert_raise(URP.SocketError, fn -> P.recv_frame(client, 1_000) end)
    end
  end

  describe inspect(&P.send_frame/2) do
    test "raises rather than failing a match when the socket is gone" do
      {client, server} = socket_pair()
      :gen_tcp.close(server)
      :gen_tcp.close(client)

      error = assert_raise(URP.SocketError, fn -> P.send_frame(client, "a request") end)

      assert is_atom(error.reason)
    end
  end

  describe inspect(&URP.SocketError.exception/1) do
    test "explains the reasons a caller is expected to act on" do
      assert Exception.message(URP.SocketError.exception(reason: :timeout)) ==
               "soffice did not answer in time"

      assert Exception.message(URP.SocketError.exception(reason: :closed)) ==
               "soffice closed the connection"
    end

    test "formats a POSIX reason it has no wording for" do
      assert Exception.message(URP.SocketError.exception(reason: :econnreset)) ==
               "socket failed: connection reset by peer"
    end
  end
end
