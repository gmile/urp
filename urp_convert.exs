# Pure Elixir URP client — full document conversion
# Converts a file to PDF via direct URP protocol to soffice
import Bitwise

encode_str = fn s -> <<byte_size(s), s::binary>> end

send_block = fn sock, msg ->
  payload = IO.iodata_to_binary(msg)
  :ok = :gen_tcp.send(sock, <<byte_size(payload)::32, 1::32, payload::binary>>)
end

recv_block = fn sock ->
  case :gen_tcp.recv(sock, 8, 120_000) do
    {:ok, <<size::32, _count::32>>} ->
      {:ok, payload} = :gen_tcp.recv(sock, size, 120_000)
      {:ok, payload}
    {:error, reason} ->
      {:error, reason}
  end
end

decode_str = fn
  <<0xFF, len::32, s::binary-size(len), rest::binary>> -> {s, rest}
  <<len, s::binary-size(len), rest::binary>> -> {s, rest}
end

# Parse queryInterface reply (returns any(XInterface) = type_desc + OID)
parse_qi_reply = fn payload, decode_str_fn ->
  <<flags, rest::binary>> = payload
  rest = if (flags &&& 0x08) != 0 do
    {_tid, rest} = decode_str_fn.(rest)
    <<_c::16, rest::binary>> = rest
    rest
  else
    rest
  end
  if (flags &&& 0x20) != 0 do
    nil
  else
    <<tc, rest::binary>> = rest
    if (tc &&& 0x7F) == 0 do
      nil  # VOID = null
    else
      <<_ci::16, rest::binary>> = rest
      rest = if (tc &&& 0x80) != 0 do
        {_name, rest} = decode_str_fn.(rest)
        rest
      else
        rest
      end
      {oid, _} = decode_str_fn.(rest)
      oid
    end
  end
end

# Parse reply returning a single interface reference (OID + cache)
parse_iface_reply = fn payload, decode_str_fn ->
  <<flags, rest::binary>> = payload
  rest = if (flags &&& 0x08) != 0 do
    {_tid, rest} = decode_str_fn.(rest)
    <<_c::16, rest::binary>> = rest
    rest
  else
    rest
  end
  if (flags &&& 0x20) != 0 do
    nil
  else
    {oid, _} = decode_str_fn.(rest)
    if byte_size(oid) == 0, do: nil, else: oid
  end
end

hex = fn bin ->
  for(<<b <- bin>>, into: "", do: String.pad_leading(Integer.to_string(b, 16), 2, "0") <> " ")
  |> String.trim()
end

# Null CurrentContext prefix (required after handshake negotiation)
null_ctx = <<0x00, 0xFF, 0xFF>>

# PropertyValue encoding helper
# PropertyValue struct: Name(string) + Handle(int32) + Value(any) + State(int32)
encode_prop = fn name, type_class, value_bytes ->
  encode_str.(name) <> <<0::32>> <> <<type_class>> <> value_bytes <> <<0::32>>
end

# =================== Parse args ===================
[infile | rest] = System.argv()
outfile = case rest do
  [o | _] -> o
  [] -> Path.rootname(infile) <> ".pdf"
end
host = "localhost"
port = 2002

in_url = "file://" <> Path.expand(infile)
out_url = "file://" <> Path.expand(outfile)
IO.puts("Converting: #{infile} → #{outfile}")
IO.puts("  in_url:  #{in_url}")
IO.puts("  out_url: #{out_url}\n")

# =================== Connect ===================
{:ok, sock} = :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false])
IO.puts("Connected to soffice at #{host}:#{port}\n")

# =================== Handshake ===================
{:ok, _} = recv_block.(sock)  # soffice's requestChange

req = <<0xF8, 4, (22 ||| 0x80), 0::16>> <>
      encode_str.("com.sun.star.bridge.XProtocolProperties") <>
      encode_str.("UrpProtocolProperties") <> <<0::16>> <>
      encode_str.(".UrpProtocolPropertiesTid") <> <<0::16>> <>
      <<-2_147_483_648::32-signed>>
send_block.(sock, req)

{:ok, <<0x80, 0::32>>} = recv_block.(sock)  # we lost (good)

send_block.(sock, <<0x80, 1::32-signed>>)  # accept soffice

{:ok, _commit} = recv_block.(sock)  # commitChange

send_block.(sock, <<0x80>>)  # reply void

IO.puts("Handshake complete")

# =================== Get Desktop ===================
# qi1: XInterface on StarOffice.ComponentContext → ctx OID
tid = :crypto.strong_rand_bytes(20)
qi1 = <<0xF8, 0, (22 ||| 0x80), 1::16>> <>
      encode_str.("com.sun.star.uno.XInterface") <>
      encode_str.("StarOffice.ComponentContext") <> <<1::16>> <>
      encode_str.(tid) <> <<1::16>> <>
      null_ctx <> <<0x16, 1::16>>
send_block.(sock, qi1)
{:ok, qi1_r} = recv_block.(sock)
ctx_oid = parse_qi_reply.(qi1_r, decode_str)
IO.puts("ComponentContext OID: #{ctx_oid}")

# qi2: XComponentContext on ctx OID (skip XInvocation/XTypeProvider, go direct)
qi2 = <<0xD0, 0>> <>
      encode_str.(ctx_oid) <> <<2::16>> <>
      null_ctx <> <<(22 ||| 0x80), 2::16>> <> encode_str.("com.sun.star.uno.XComponentContext")
send_block.(sock, qi2)
{:ok, qi2_r} = recv_block.(sock)
IO.puts("XComponentContext qi reply: #{hex.(qi2_r)}")

# getServiceManager (funcID=4 on XComponentContext)
# XComponentContext: qi=0, acquire=1, release=2, getValueByName=3, getServiceManager=4
gsm = <<0xE0, 4, (22 ||| 0x80), 3::16>> <>
      encode_str.("com.sun.star.uno.XComponentContext") <>
      null_ctx
send_block.(sock, gsm)
{:ok, gsm_r} = recv_block.(sock)
smgr_oid = parse_iface_reply.(gsm_r, decode_str)
IO.puts("ServiceManager OID: #{smgr_oid}")

# createInstanceWithContext("com.sun.star.frame.Desktop") on XMultiComponentFactory
# funcID=3: qi=0, acquire=1, release=2, createInstanceWithContext=3
create = <<0xF0, 3, (22 ||| 0x80), 4::16>> <>
         encode_str.("com.sun.star.lang.XMultiComponentFactory") <>
         encode_str.(smgr_oid) <> <<3::16>> <>
         null_ctx <>
         encode_str.("com.sun.star.frame.Desktop") <>
         <<0x00, 2::16>>  # context ref: empty OID string + cache 2 (ctx_oid)
send_block.(sock, create)
{:ok, create_r} = recv_block.(sock)
desktop_oid = parse_iface_reply.(create_r, decode_str)
IO.puts("Desktop OID: #{desktop_oid}\n")

# =================== Load Document ===================
# qi for XComponentLoader on Desktop
qi_loader = <<0xF0, 0, 0x16, 1::16>> <>  # type: XInterface (cache 1)
            encode_str.(desktop_oid) <> <<4::16>> <>
            null_ctx <> <<(22 ||| 0x80), 5::16>> <> encode_str.("com.sun.star.frame.XComponentLoader")
send_block.(sock, qi_loader)
{:ok, _qi_loader_r} = recv_block.(sock)
# Reply may be null but loadComponentFromURL should still work on the same OID

# loadComponentFromURL(URL, "_blank", 0, [Hidden=true])
# funcID=3 on XComponentLoader: qi=0, acquire=1, release=2, loadComponentFromURL=3
load = <<0xE0, 3, (22 ||| 0x80), 6::16>> <>
       encode_str.("com.sun.star.frame.XComponentLoader") <>
       null_ctx <>
       encode_str.(in_url) <>
       encode_str.("_blank") <>
       <<0::32>> <>  # SearchFlags = 0
       <<1>> <>  # sequence length 1
       encode_prop.("Hidden", 0x02, <<0x01>>)  # PropertyValue: Hidden = true (BOOLEAN)
send_block.(sock, load)
IO.puts("Loading #{in_url}...")
{:ok, load_r} = recv_block.(sock)
doc_oid = parse_iface_reply.(load_r, decode_str)
IO.puts("Document OID: #{inspect(doc_oid)}")

if is_nil(doc_oid) do
  IO.puts("ERROR: Failed to load document (null OID)")
  IO.puts("Reply hex: #{hex.(load_r)}")
  :gen_tcp.close(sock)
  System.halt(1)
end

# =================== Store as PDF ===================
# qi for XStorable2 on document
qi_stor = <<0xF0, 0, 0x16, 1::16>> <>
          encode_str.(doc_oid) <> <<5::16>> <>
          null_ctx <> <<(22 ||| 0x80), 7::16>> <> encode_str.("com.sun.star.frame.XStorable2")
send_block.(sock, qi_stor)
{:ok, _qi_stor_r} = recv_block.(sock)

# storeToURL(URL, [FilterName="writer_pdf_Export"])
# funcID=8 on XStorable2: qi=0..release=2, hasLocation=3, getLocation=4, isReadonly=5, store=6, storeAsURL=7, storeToURL=8
store = <<0xE0, 8, (22 ||| 0x80), 8::16>> <>
        encode_str.("com.sun.star.frame.XStorable2") <>
        null_ctx <>
        encode_str.(out_url) <>
        <<1>> <>  # sequence length 1
        encode_prop.("FilterName", 0x0C, encode_str.("writer_pdf_Export"))
send_block.(sock, store)
IO.puts("Storing as PDF to #{out_url}...")
{:ok, store_r} = recv_block.(sock)
IO.puts("storeToURL reply: #{hex.(store_r)}")

# =================== Close Document ===================
# qi for XCloseable on document
qi_close = <<0xF0, 0, 0x16, 1::16>> <>
           encode_str.(doc_oid) <> <<6::16>> <>
           null_ctx <> <<(22 ||| 0x80), 9::16>> <> encode_str.("com.sun.star.util.XCloseable")
send_block.(sock, qi_close)
{:ok, _qi_close_r} = recv_block.(sock)

# close(deliverOwnership=true)
# From capture: funcID=5 on XCloseable, body = null_ctx + boolean true
close_msg = <<0xE0, 5, 0x16, 9::16>> <>
            null_ctx <> <<0x01>>  # boolean true
send_block.(sock, close_msg)
{:ok, _close_r} = recv_block.(sock)
IO.puts("Document closed")

:gen_tcp.close(sock)
IO.puts("\nConversion complete: #{outfile}")

# Verify the output
if File.exists?(outfile) do
  stat = File.stat!(outfile)
  IO.puts("Output file size: #{stat.size} bytes")
else
  IO.puts("WARNING: Output file not found at #{outfile}")
  IO.puts("  (The file was written inside the Docker container at #{out_url})")
end
