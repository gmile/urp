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

  @tc_void 0

  @doc """
  Receive frames while handling XInputStream calls from soffice.

  Dispatches readBytes/readSomeBytes/available/closeInput/skipBytes calls
  until we receive the reply to our pending request. Returns the reply payload.
  """
  def recv_handling_input(sock, data, pos \\ 0) do
    payload = P.recv_frame(sock)

    if P.is_reply?(payload) do
      payload
    else
      %{func_id: func_id, body: body} = P.parse_request(payload)
      {reply, pos} = handle_input(func_id, body, data, pos)
      P.send_frame(sock, reply)
      recv_handling_input(sock, data, pos)
    end
  end

  @doc """
  Receive frames while handling XOutputStream calls from soffice.

  Dispatches writeBytes/flush/closeOutput calls until we receive the reply
  to our pending request. Returns `{reply_payload, output_bytes}`.
  """
  def recv_handling_output(sock, chunks \\ []) do
    payload = P.recv_frame(sock)

    if P.is_reply?(payload) do
      {payload, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    else
      %{func_id: func_id, body: body} = P.parse_request(payload)
      {reply, chunks} = handle_output(func_id, body, chunks)
      P.send_frame(sock, reply)
      recv_handling_output(sock, chunks)
    end
  end

  ## XInputStream handlers

  # queryInterface — return null for all types
  defp handle_input(0, _body, _data, pos), do: {P.reply(<<@tc_void>>), pos}
  # acquire / release — acknowledge
  defp handle_input(1, _body, _data, pos), do: {P.reply(), pos}
  defp handle_input(2, _body, _data, pos), do: {P.reply(), pos}

  # readBytes([in] long nBytesToRead) → long + [out] sequence<byte>
  defp handle_input(3, body, data, pos) do
    n = parse_long_param(body)
    {chunk, pos} = read_chunk(data, pos, n)
    {P.reply(<<byte_size(chunk)::32-signed>> <> P.enc_str(chunk)), pos}
  end

  # readSomeBytes — same behavior as readBytes for an in-memory buffer
  defp handle_input(4, body, data, pos), do: handle_input(3, body, data, pos)

  # skipBytes([in] long nBytesToSkip) → void
  defp handle_input(5, body, _data, pos) do
    {P.reply(), pos + parse_long_param(body)}
  end

  # available() → long
  defp handle_input(6, _body, data, pos) do
    {P.reply(<<byte_size(data) - pos::32-signed>>), pos}
  end

  # closeInput() → void
  defp handle_input(7, _body, _data, pos), do: {P.reply(), pos}

  ## XOutputStream handlers

  # queryInterface — return null
  defp handle_output(0, _body, chunks), do: {P.reply(<<@tc_void>>), chunks}
  # acquire / release
  defp handle_output(1, _body, chunks), do: {P.reply(), chunks}
  defp handle_output(2, _body, chunks), do: {P.reply(), chunks}

  # writeBytes([in] sequence<byte>) → void
  defp handle_output(3, body, chunks) do
    body = skip_null_ctx(body)
    {data, _rest} = P.dec_str(body)
    {P.reply(), [data | chunks]}
  end

  # flush() → void
  defp handle_output(4, _body, chunks), do: {P.reply(), chunks}

  # closeOutput() → void
  defp handle_output(5, _body, chunks), do: {P.reply(), chunks}

  ## Helpers

  defp read_chunk(data, pos, n) do
    remaining = byte_size(data) - pos
    to_read = min(n, max(remaining, 0))
    {binary_part(data, pos, to_read), pos + to_read}
  end

  defp parse_long_param(body) do
    <<_null_ctx::3-bytes, n::32-signed, _::binary>> = body
    n
  end

  defp skip_null_ctx(<<_::3-bytes, rest::binary>>), do: rest
  defp skip_null_ctx(rest), do: rest
end
