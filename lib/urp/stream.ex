defmodule URP.Stream do
  @moduledoc """
  Bidirectional URP dispatch for XInputStream/XOutputStream/XSeekable.

  When we pass a stream object reference to soffice (e.g. as an InputStream
  in a MediaDescriptor), soffice calls methods on our object over the same
  TCP connection. This module handles those incoming calls while we wait
  for the reply to our original request.

  ## XInputStream funcIDs (depth-first interface traversal)

      XInterface: queryInterface=0, acquire=1, release=2
      XInputStream: readBytes=3, readSomeBytes=4, skipBytes=5, available=6, closeInput=7

  ## XSeekable funcIDs

      XInterface: queryInterface=0, acquire=1, release=2
      XSeekable: seek=3, getPosition=4, getLength=5

  Since XInputStream and XSeekable share funcIDs 3-5, we use the URP type
  cache to disambiguate: each request carries a type reference telling us
  which interface it targets.

  ## XOutputStream funcIDs

      XInterface: queryInterface=0, acquire=1, release=2
      XOutputStream: writeBytes=3, flush=4, closeOutput=5
  """

  alias URP.Protocol, as: P

  import Bitwise

  @type input_source :: binary() | {:file, pid(), non_neg_integer()} | {:enum, binary(), pid()}
  @typep source ::
           {:mem, binary(), non_neg_integer()}
           | {:file, pid(), non_neg_integer()}
           | {:enum, binary(), pid() | :eof}
  @type sink :: nil | {:path, Path.t()} | (binary() -> any())

  @tc_void 0
  @tc_new 0x80
  @tc_interface 22

  @xi_seekable "com.sun.star.io.XSeekable"

  # Our outgoing type cache index for XSeekable (bridge.ex uses 0–16)
  @seekable_out_type_cache 17

  # OID encoding: 0 = cached reference, then 16-bit cache index
  @oid_cached 0

  # OID cache slot 10 = exported input stream (set in bridge.ex loadComponentFromURL)
  @oid_cache_export_input 10

  @doc """
  Receive frames while handling XInputStream/XSeekable calls from soffice.

  `source` is either a binary (in-memory), `{:file, pid, size}` for
  file-backed streaming, or `{:enum, buffer, reader}` for enumerables.

  When `stream_oid` is provided and the source is seekable (memory or file),
  queryInterface for XSeekable is supported — enabling ZIP-based formats
  like docx and xlsx.

  Dispatches calls until we receive the reply to our pending request.
  Returns the reply payload.
  """
  @spec recv_handling_input(
          :gen_tcp.socket(),
          input_source() | source(),
          String.t() | nil
        ) :: binary()
  def recv_handling_input(sock, data, stream_oid \\ nil)

  def recv_handling_input(sock, data, stream_oid) when is_binary(data) do
    recv_handling_input(sock, {:mem, data, 0}, stream_oid)
  end

  def recv_handling_input(sock, source, stream_oid) do
    do_recv_input(
      sock,
      source,
      stream_oid,
      _seekable_cache = nil,
      _last_type = nil,
      _input_cache = nil
    )
  end

  defp do_recv_input(sock, source, stream_oid, seekable_cache, last_type, input_cache) do
    payload = P.recv_frame(sock)

    if P.is_reply?(payload) do
      # Save input context so the stream can be served during store/close phases
      if seekable_cache do
        Process.put(:urp_input_ctx, %{
          source: source,
          seekable_cache: seekable_cache,
          input_cache: input_cache
        })
      end

      payload
    else
      %{func_id: func_id, body: body, type_cache: type_cache, tid: new_tid} =
        P.parse_request(payload)

      tid = track_tid(new_tid)
      active_type = type_cache || last_type
      track_type(type_cache)
      input_cache = input_cache || type_cache

      {reply, source, seekable_cache} =
        dispatch_input(func_id, active_type, body, source, stream_oid, seekable_cache)

      if not P.one_way?(func_id), do: P.send_frame(sock, inject_tid(reply, tid))
      do_recv_input(sock, source, stream_oid, seekable_cache, active_type, input_cache)
    end
  end

  @doc """
  Try to handle a stray request as an input stream call.

  Called by `Bridge.recv_reply!/1` when it encounters a non-reply message
  outside the main stream recv loop. Returns `:not_input` if the request
  doesn't match the active input stream context.
  """
  @spec try_handle_input(:gen_tcp.socket(), binary()) :: :handled | :not_input
  def try_handle_input(sock, payload) do
    case Process.get(:urp_input_ctx) do
      nil ->
        :not_input

      ctx ->
        %{func_id: func_id, body: body, type_cache: type_cache, tid: new_tid} =
          P.parse_request(payload)

        tid = track_tid(new_tid)
        # Use the global reader type (updated by all recv loops), not the
        # stale load-phase ctx.last_type which doesn't see store-phase types.
        active_type = track_type(type_cache)

        cond do
          func_id <= 2 ->
            # QI, acquire, release — handled generically by the caller
            :not_input

          ctx.seekable_cache != nil and active_type == ctx.seekable_cache ->
            {reply, source} = handle_seekable(func_id, body, ctx.source)
            if not P.one_way?(func_id), do: P.send_frame(sock, inject_tid(reply, tid))
            Process.put(:urp_input_ctx, %{ctx | source: source})
            :handled

          active_type == ctx.input_cache ->
            {reply, source} = handle_input(func_id, body, ctx.source)
            if not P.one_way?(func_id), do: P.send_frame(sock, inject_tid(reply, tid))
            Process.put(:urp_input_ctx, %{ctx | source: source})
            :handled

          true ->
            :not_input
        end
    end
  end

  @doc "Clear the saved input context. Call after the conversion is complete."
  @spec clear_input_ctx() :: :ok
  def clear_input_ctx do
    Process.delete(:urp_input_ctx)
    Process.delete(:urp_reply_tid)
    Process.delete(:urp_reader_type)
    Process.delete(:urp_tid_cache)
    :ok
  end

  @doc false
  @spec track_tid(binary() | nil) :: binary() | nil
  def track_tid(nil), do: Process.get(:urp_reply_tid)

  def track_tid(tid) when is_binary(tid) do
    Process.put(:urp_reply_tid, tid)
    tid
  end

  @doc false
  @spec track_type(non_neg_integer() | nil) :: non_neg_integer() | nil
  def track_type(nil), do: Process.get(:urp_reader_type)

  def track_type(tc) when is_integer(tc) do
    Process.put(:urp_reader_type, tc)
    tc
  end

  @doc false
  @spec inject_tid(binary(), binary() | nil) :: binary()
  def inject_tid(reply, nil), do: reply
  def inject_tid(<<0x80>>, tid), do: P.reply_with_tid(tid)
  def inject_tid(<<0x80, body::binary>>, tid), do: P.reply_with_tid(body, tid)

  # XInterface methods (0=queryInterface, 1=acquire, 2=release) — shared by all interfaces
  defp dispatch_input(0, _type, body, source, stream_oid, seekable_cache) do
    if stream_oid != nil and seekable_source?(source) and qi_for_seekable?(body) do
      # Accept XSeekable — reply with any(XSeekable) pointing at the same stream OID.
      # Type cache is per-direction: use TC_NEW with full type name in OUR outgoing cache.
      incoming_cache = parse_qi_cache(body)

      # The stream OID was registered at OID cache 10 in our outgoing cache
      # (from the InputStream property in loadComponentFromURL).
      # Use a cached OID reference to match soffice's own QI reply style.
      reply =
        P.reply(
          <<@tc_interface ||| @tc_new, @seekable_out_type_cache::16>> <>
            P.enc_str(@xi_seekable) <>
            <<@oid_cached, @oid_cache_export_input::16>>
        )

      {reply, source, incoming_cache}
    else
      {P.reply(<<@tc_void>>), source, seekable_cache}
    end
  end

  defp dispatch_input(1, _type, _body, source, _oid, sc), do: {P.reply(), source, sc}
  defp dispatch_input(2, _type, _body, source, _oid, sc), do: {P.reply(), source, sc}

  # funcIDs 3+ — dispatch based on active type (XInputStream vs XSeekable)
  defp dispatch_input(func_id, type, body, source, _oid, seekable_cache) do
    handler =
      if seekable_cache != nil and type == seekable_cache,
        do: &handle_seekable/3,
        else: &handle_input/3

    {reply, source} = handler.(func_id, body, source)
    {reply, source, seekable_cache}
  end

  ## QI helpers

  # ZIP (docx/xlsx/pptx/odt) and OLE2 (doc/xls/ppt) archives require seeking.
  # Plain text, CSV, HTML, RTF etc. are forward-only and loop if XSeekable is accepted.
  @zip_magic "PK"
  @ole2_magic <<0xD0, 0xCF, 0x11, 0xE0>>
  @magic_bytes_len max(byte_size(@zip_magic), byte_size(@ole2_magic))

  defp seekable_source?({:enum, _, _}), do: false

  defp seekable_source?({:mem, data, _pos}) do
    match?(@zip_magic <> _, data) or match?(@ole2_magic <> _, data)
  end

  defp seekable_source?({:file, fd, _size}) do
    {:ok, pos} = :file.position(fd, :cur)
    {:ok, _} = :file.position(fd, {:bof, 0})
    magic = IO.binread(fd, @magic_bytes_len)
    {:ok, _} = :file.position(fd, {:bof, pos})
    is_binary(magic) and (match?(@zip_magic <> _, magic) or match?(@ole2_magic <> _, magic))
  end

  defp qi_for_seekable?(body) do
    # body: <<null_ctx::3, tc, cache::16, [name]>>
    <<_ctx::3-bytes, rest::binary>> = body

    case rest do
      <<tc, _cache::16, rest::binary>> when tc >= 128 ->
        {name, _} = P.dec_str(rest)
        name == @xi_seekable

      _ ->
        false
    end
  end

  defp parse_qi_cache(body) do
    <<_ctx::3-bytes, _tc, cache::16, _::binary>> = body
    cache
  end

  ## XInputStream handlers — funcIDs: readBytes=3, readSomeBytes=4, skipBytes=5, available=6, closeInput=7

  defp handle_input(3, body, src) do
    n = parse_long_param(body)
    {chunk, src} = read_chunk(src, n)
    {P.reply(<<byte_size(chunk)::32-signed>> <> P.enc_str(chunk)), src}
  end

  defp handle_input(4, body, src), do: handle_input(3, body, src)

  defp handle_input(5, body, src) do
    {P.reply(), skip_chunk(src, parse_long_param(body))}
  end

  defp handle_input(6, _body, src) do
    {P.reply(<<available(src)::32-signed>>), src}
  end

  defp handle_input(7, _body, src), do: {P.reply(), src}

  ## XSeekable handlers — funcIDs: seek=3, getPosition=4, getLength=5

  defp handle_seekable(3, body, src) do
    {P.reply(), seek_to(src, parse_hyper_param(body))}
  end

  defp handle_seekable(4, _body, src) do
    {P.reply(<<get_position(src)::64-signed>>), src}
  end

  defp handle_seekable(5, _body, src) do
    {P.reply(<<get_length(src)::64-signed>>), src}
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
      # soffice may interleave input stream requests (lazy content loading) during store
      case try_handle_input(sock, payload) do
        :handled ->
          do_recv_output(sock, sink)

        :not_input ->
          %{func_id: func_id, body: body, tid: new_tid, type_cache: tc} =
            P.parse_request(payload)

          tid = track_tid(new_tid)
          track_type(tc)
          {reply, sink} = handle_output(func_id, body, sink)
          if not P.one_way?(func_id), do: P.send_frame(sock, inject_tid(reply, tid))
          do_recv_output(sock, sink)
      end
    end
  end

  ## XOutputStream handlers — funcIDs: writeBytes=3, flush=4, closeOutput=5

  defp handle_output(0, _body, sink), do: {P.reply(<<@tc_void>>), sink}
  defp handle_output(1, _body, sink), do: {P.reply(), sink}
  defp handle_output(2, _body, sink), do: {P.reply(), sink}

  defp handle_output(3, body, sink) do
    {data, _} = body |> skip_null_ctx() |> P.dec_str()
    {P.reply(), write_sink(sink, data)}
  end

  defp handle_output(4, _body, sink), do: {P.reply(), sink}
  defp handle_output(5, _body, sink), do: {P.reply(), sink}

  ## Sink helpers

  defp write_sink({:mem, chunks}, data), do: {:mem, [data | chunks]}

  defp write_sink({:file, fd} = sink, data) do
    IO.binwrite(fd, data)
    sink
  end

  defp write_sink({:fun, fun} = sink, data) do
    fun.(data)
    sink
  end

  defp finalize_sink({:mem, chunks}), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()
  defp finalize_sink({:file, _fd}), do: :ok
  defp finalize_sink({:fun, _fun}), do: :ok

  ## Source-polymorphic read helpers
  ##
  ## Memory sources track position: {:mem, data, pos}
  ## File sources track total size: {:file, fd, size} — position via fd
  ## Enum sources are forward-only: {:enum, buffer, reader}

  # In-memory binary — position-based
  defp read_chunk({:mem, data, pos}, n) do
    remaining = byte_size(data) - pos
    to_read = min(n, max(remaining, 0))
    chunk = binary_part(data, pos, to_read)
    {chunk, {:mem, data, pos + to_read}}
  end

  # File-backed — position tracked by fd
  defp read_chunk({:file, fd, size}, n) do
    {:ok, pos} = :file.position(fd, :cur)
    remaining = size - pos
    to_read = min(n, max(remaining, 0))

    chunk =
      case IO.binread(fd, to_read) do
        data when is_binary(data) -> data
        _ -> <<>>
      end

    {chunk, {:file, fd, size}}
  end

  # Enumerable-backed
  defp read_chunk({:enum, buffer, reader}, n) do
    {buffer, reader} = fill_buffer(buffer, reader, n)
    to_read = min(n, byte_size(buffer))
    <<chunk::binary-size(to_read), rest::binary>> = buffer
    {chunk, {:enum, rest, reader}}
  end

  defp skip_chunk({:mem, data, pos}, n) do
    remaining = byte_size(data) - pos
    {:mem, data, pos + min(n, remaining)}
  end

  defp skip_chunk({:file, fd, size}, n) do
    {:ok, pos} = :file.position(fd, :cur)
    skip = min(n, size - pos)
    {:ok, _} = :file.position(fd, {:cur, skip})
    {:file, fd, size}
  end

  defp skip_chunk({:enum, buffer, reader}, n) do
    {buffer, reader} = fill_buffer(buffer, reader, n)
    skip = min(n, byte_size(buffer))
    <<_::binary-size(skip), rest::binary>> = buffer
    {:enum, rest, reader}
  end

  defp available({:mem, data, pos}), do: byte_size(data) - pos

  defp available({:file, fd, size}) do
    {:ok, pos} = :file.position(fd, :cur)
    size - pos
  end

  defp available({:enum, buffer, :eof}), do: byte_size(buffer)

  # Unknown remaining size — return a large value so soffice keeps reading
  defp available({:enum, _buffer, _reader}), do: 1_000_000

  ## XSeekable source helpers

  defp seek_to({:mem, data, _pos}, target) do
    {:mem, data, min(max(target, 0), byte_size(data))}
  end

  defp seek_to({:file, fd, size}, target) do
    {:ok, _} = :file.position(fd, {:bof, min(max(target, 0), size)})
    {:file, fd, size}
  end

  defp get_position({:mem, _data, pos}), do: pos

  defp get_position({:file, fd, _size}) do
    {:ok, pos} = :file.position(fd, :cur)
    pos
  end

  defp get_length({:mem, data, _pos}), do: byte_size(data)
  defp get_length({:file, _fd, size}), do: size

  @doc """
  Spawn a linked process that iterates `enumerable`, sending chunks to the caller.

  The reader sends `{pid, {:chunk, data}}` for each element and `{pid, :eof}`
  when the enumerable is exhausted. The caller receives these in `fill_buffer/3`.
  """
  @spec start_enum_reader(Enumerable.t()) :: pid()
  def start_enum_reader(enumerable) do
    parent = self()

    spawn_link(fn ->
      Enum.each(enumerable, fn chunk ->
        data = IO.iodata_to_binary(chunk)
        send(parent, {self(), {:chunk, data}})
      end)

      send(parent, {self(), :eof})
    end)
  end

  defp fill_buffer(buffer, :eof, _needed), do: {buffer, :eof}

  defp fill_buffer(buffer, reader, needed) when byte_size(buffer) >= needed,
    do: {buffer, reader}

  defp fill_buffer(buffer, reader, needed) do
    receive do
      {^reader, {:chunk, data}} ->
        fill_buffer(buffer <> data, reader, needed)

      {^reader, :eof} ->
        {buffer, :eof}
    end
  end

  defp parse_long_param(body) do
    <<_null_ctx::3-bytes, n::32-signed, _::binary>> = body
    n
  end

  defp parse_hyper_param(body) do
    <<_null_ctx::3-bytes, n::64-signed, _::binary>> = body
    n
  end

  defp skip_null_ctx(<<_::3-bytes, rest::binary>>), do: rest
  defp skip_null_ctx(rest), do: rest
end
