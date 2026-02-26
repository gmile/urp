defmodule URP.Stream do
  @moduledoc """
  Bidirectional URP dispatch for XInputStream/XOutputStream.

  When we pass a stream object reference to soffice (e.g. as an InputStream
  in a MediaDescriptor), soffice calls methods on our object over the same
  TCP connection. This module handles those incoming calls while we wait
  for the reply to our original request.

  ## XInputStream funcIDs (depth-first interface traversal)

      XInterface: queryInterface=0, acquire=1, release=2
      XInputStream: readBytes=3, readSomeBytes=4, skipBytes=5, available=6, closeInput=7

  ## XOutputStream funcIDs

      XInterface: queryInterface=0, acquire=1, release=2
      XOutputStream: writeBytes=3, flush=4, closeOutput=5
  """

  alias URP.Protocol, as: P

  @type input_source :: binary() | {:file, pid(), non_neg_integer()}
  @typep source :: {:mem, binary(), non_neg_integer()} | {:file, pid(), non_neg_integer()}
  @type sink :: nil | {:path, Path.t()} | (binary() -> any())

  @tc_void 0

  @doc """
  Receive frames while handling XInputStream calls from soffice.

  `source` is either a binary (in-memory) or `{:file, pid, size}` for
  file-backed streaming via `File.open!/2`.

  Dispatches readBytes/readSomeBytes/available/closeInput/skipBytes calls
  until we receive the reply to our pending request. Returns the reply payload.
  """
  @spec recv_handling_input(:gen_tcp.socket(), input_source() | source(), non_neg_integer()) ::
          binary()
  def recv_handling_input(sock, data, pos \\ 0)

  def recv_handling_input(sock, data, pos) when is_binary(data) do
    recv_handling_input(sock, {:mem, data, byte_size(data)}, pos)
  end

  def recv_handling_input(sock, source, _pos) do
    payload = P.recv_frame(sock)

    if P.is_reply?(payload) do
      payload
    else
      %{func_id: func_id, body: body, one_way: one_way} = P.parse_request(payload)
      {reply, source} = handle_input(func_id, body, source)
      unless one_way, do: P.send_frame(sock, reply)
      recv_handling_input(sock, source, 0)
    end
  end

  @doc """
  Receive frames while handling XOutputStream calls from soffice.

  `sink` controls where output bytes go:

    * `nil` (default) — accumulate in memory, returns `{reply, binary}`
    * `{:path, path}` — write chunks to file as they arrive, returns `{reply, :ok}`
    * `fun/1` — call with each chunk, returns `{reply, :ok}`
  """
  @spec recv_handling_output(:gen_tcp.socket(), sink()) :: {binary(), binary() | :ok}
  def recv_handling_output(sock, sink \\ nil)

  def recv_handling_output(sock, nil) do
    do_recv_output(sock, {:mem, []})
  end

  def recv_handling_output(sock, {:path, path}) do
    fd = File.open!(path, [:write, :binary, :raw])

    try do
      do_recv_output(sock, {:file, fd})
    after
      File.close(fd)
    end
  end

  def recv_handling_output(sock, fun) when is_function(fun, 1) do
    do_recv_output(sock, {:fun, fun})
  end

  defp do_recv_output(sock, sink) do
    payload = P.recv_frame(sock)

    if P.is_reply?(payload) do
      {payload, finalize_sink(sink)}
    else
      %{func_id: func_id, body: body, one_way: one_way} = P.parse_request(payload)
      {reply, sink} = handle_output(func_id, body, sink)
      unless one_way, do: P.send_frame(sock, reply)
      do_recv_output(sock, sink)
    end
  end

  ## XInputStream handlers

  # queryInterface — return null for all types
  defp handle_input(0, _body, src), do: {P.reply(<<@tc_void>>), src}
  # acquire / release — acknowledge
  defp handle_input(1, _body, src), do: {P.reply(), src}
  defp handle_input(2, _body, src), do: {P.reply(), src}

  # readBytes([in] long nBytesToRead) → long + [out] sequence<byte>
  defp handle_input(3, body, src) do
    n = parse_long_param(body)
    {chunk, src} = read_chunk(src, n)
    {P.reply(<<byte_size(chunk)::32-signed>> <> P.enc_str(chunk)), src}
  end

  # readSomeBytes — same behavior as readBytes
  defp handle_input(4, body, src), do: handle_input(3, body, src)

  # skipBytes([in] long nBytesToSkip) → void
  defp handle_input(5, body, src) do
    {P.reply(), skip_chunk(src, parse_long_param(body))}
  end

  # available() → long
  defp handle_input(6, _body, src) do
    {P.reply(<<available(src)::32-signed>>), src}
  end

  # closeInput() → void
  defp handle_input(7, _body, src), do: {P.reply(), src}

  ## XOutputStream handlers

  # queryInterface — return null
  defp handle_output(0, _body, sink), do: {P.reply(<<@tc_void>>), sink}
  # acquire / release
  defp handle_output(1, _body, sink), do: {P.reply(), sink}
  defp handle_output(2, _body, sink), do: {P.reply(), sink}

  # writeBytes([in] sequence<byte>) → void
  defp handle_output(3, body, sink) do
    body = skip_null_ctx(body)
    {data, _rest} = P.dec_str(body)
    {P.reply(), write_sink(sink, data)}
  end

  # flush() → void
  defp handle_output(4, _body, sink), do: {P.reply(), sink}

  # closeOutput() → void
  defp handle_output(5, _body, sink), do: {P.reply(), sink}

  ## Sink helpers

  defp write_sink({:mem, chunks}, data), do: {:mem, [data | chunks]}

  defp write_sink({:file, fd} = sink, data),
    do:
      (
        IO.binwrite(fd, data)
        sink
      )

  defp write_sink({:fun, fun} = sink, data),
    do:
      (
        fun.(data)
        sink
      )

  defp finalize_sink({:mem, chunks}), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()
  defp finalize_sink({:file, _fd}), do: :ok
  defp finalize_sink({:fun, _fun}), do: :ok

  ## Source-polymorphic helpers

  # In-memory binary
  defp read_chunk({:mem, data, size} = _src, n) do
    pos = byte_size(data) - size
    to_read = min(n, max(size, 0))
    chunk = binary_part(data, pos, to_read)
    {chunk, {:mem, data, size - to_read}}
  end

  # File-backed
  defp read_chunk({:file, fd, remaining}, n) do
    to_read = min(n, max(remaining, 0))

    chunk =
      case IO.binread(fd, to_read) do
        data when is_binary(data) -> data
        _ -> <<>>
      end

    {chunk, {:file, fd, remaining - byte_size(chunk)}}
  end

  defp skip_chunk({:mem, data, size}, n), do: {:mem, data, size - min(n, size)}

  defp skip_chunk({:file, fd, remaining}, n) do
    skip = min(n, remaining)
    {:ok, _} = :file.position(fd, {:cur, skip})
    {:file, fd, remaining - skip}
  end

  defp available({:mem, _data, size}), do: size
  defp available({:file, _fd, remaining}), do: remaining

  defp parse_long_param(body) do
    <<_null_ctx::3-bytes, n::32-signed, _::binary>> = body
    n
  end

  defp skip_null_ctx(<<_::3-bytes, rest::binary>>), do: rest
  defp skip_null_ctx(rest), do: rest
end
