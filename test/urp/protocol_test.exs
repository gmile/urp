defmodule URP.ProtocolTest do
  use ExUnit.Case, async: true

  alias URP.Protocol, as: P

  import Bitwise

  describe "parse_request/1 — long header" do
    test "basic long header with 8-bit func_id" do
      # LONGHEADER | REQUEST | NEWTYPE, func_id=3, cached type (tc=22, cache=1)
      header = <<0xC0 ||| 0x20, 3, 22, 0::16>>
      %{func_id: 3, body: <<>>} = P.parse_request(header)
    end

    test "FUNCTIONID16 reads 16-bit func_id" do
      # LONGHEADER | REQUEST | FUNCTIONID16 (0x04), func_id=300
      header = <<0xC0 ||| 0x04, 300::16>>
      %{func_id: 300, body: <<>>} = P.parse_request(header)
    end

    test "MOREFLAGS byte is skipped" do
      # LONGHEADER | REQUEST | MOREFLAGS (0x01), flags2=0x80
      header = <<0xC0 ||| 0x01, 0x80, 5>>
      %{func_id: 5, body: <<>>} = P.parse_request(header)
    end

    test "skips NEWTYPE with cached type" do
      # LONGHEADER | REQUEST | NEWTYPE, func_id=0, cached type (tc=22, cache=5)
      body = "remaining"
      header = <<0xC0 ||| 0x20, 0, 22, 5::16>> <> body
      %{func_id: 0, body: ^body} = P.parse_request(header)
    end

    test "skips NEWTYPE with new type (includes type name)" do
      type_name = "com.sun.star.uno.XInterface"
      encoded_name = P.enc_str(type_name)
      body = "remaining"
      # tc = 22 | 0x80 (new), cache=1
      header = <<0xC0 ||| 0x20, 0, 22 ||| 0x80, 1::16>> <> encoded_name <> body
      %{func_id: 0, body: ^body} = P.parse_request(header)
    end

    test "skips NEWOID" do
      oid = "some-oid-123"
      body = "remaining"
      # LONGHEADER | REQUEST | NEWOID
      header = <<0xC0 ||| 0x10, 7>> <> P.enc_str(oid) <> <<3::16>> <> body
      %{func_id: 7, body: ^body} = P.parse_request(header)
    end

    test "skips NEWTID" do
      tid = "some-tid"
      body = "remaining"
      # LONGHEADER | REQUEST | NEWTID
      header = <<0xC0 ||| 0x08, 2>> <> P.enc_str(tid) <> <<0::16>> <> body
      %{func_id: 2, body: ^body} = P.parse_request(header)
    end

    test "all flags combined" do
      type_name = "com.sun.star.io.XInputStream"
      oid = "stream-42"
      tid = "tid-1"
      body = <<1, 2, 3>>

      # LONGHEADER | REQUEST | MOREFLAGS | NEWTYPE | NEWOID | NEWTID
      flags = 0xC0 ||| 0x01 ||| 0x20 ||| 0x10 ||| 0x08
      # MUSTREPLY
      flags2 = 0x80

      header =
        <<flags, flags2, 3>> <>
          <<22 ||| 0x80, 5::16>> <>
          P.enc_str(type_name) <>
          P.enc_str(oid) <>
          <<7::16>> <>
          P.enc_str(tid) <>
          <<1::16>> <>
          body

      %{func_id: 3, body: ^body} = P.parse_request(header)
    end
  end

  describe "parse_request/1 — short header" do
    test "6-bit func_id" do
      body = <<1, 2, 3>>
      # Short header: bit 7 clear, func_id in lower 6 bits
      header = <<42>> <> body
      %{func_id: 42, body: ^body} = P.parse_request(header)
    end

    test "14-bit func_id (FUNCTIONID14)" do
      body = <<1, 2, 3>>
      # Short header with bit 6 set: func_id = bits[5:0] << 8 | next_byte
      # func_id = 0x03 << 8 | 0x05 = 773
      header = <<0x40 ||| 0x03, 0x05>> <> body
      %{func_id: 773, body: ^body} = P.parse_request(header)
    end
  end

  describe "one_way?/1" do
    test "release (func_id 2) is one-way" do
      assert P.one_way?(2)
    end

    test "other func_ids are not one-way" do
      refute P.one_way?(0)
      refute P.one_way?(1)
      refute P.one_way?(3)
      refute P.one_way?(7)
    end
  end

  describe "is_reply?/1" do
    test "long header reply" do
      assert P.is_reply?(<<0x80, 0, 0, 0, 0>>)
    end

    test "long header reply with exception" do
      assert P.is_reply?(<<0x80 ||| 0x20, "rest">>)
    end

    test "long header request is not a reply" do
      refute P.is_reply?(<<0xC0, 0>>)
    end

    test "short header is not a reply" do
      refute P.is_reply?(<<0x03, "body">>)
    end
  end

  describe "parse_exception/1" do
    test "extracts message from exception with new type" do
      message = "file not found"

      # Reply with EXCEPTION flag, Any body: new exception type (tc=19|0x80) + cache + name + message
      exc_type = "com.sun.star.io.IOException"

      payload =
        <<0x80 ||| 0x20>> <>
          <<19 ||| 0x80, 0::16>> <>
          P.enc_str(exc_type) <>
          P.enc_str(message)

      assert P.parse_exception(payload) == message
    end

    test "extracts message from exception with cached type" do
      message = "access denied"
      # Reply with EXCEPTION flag, Any body: cached exception type (tc=19) + cache + message
      payload = <<0x80 ||| 0x20>> <> <<19, 0::16>> <> P.enc_str(message)
      assert P.parse_exception(payload) == message
    end

    test "returns fallback for malformed exception" do
      # Reply with EXCEPTION flag but truncated body
      payload = <<0x80 ||| 0x20>>
      assert P.parse_exception(payload) == "UNO exception (could not parse message)"
    end

    test "returns nil for non-exception reply" do
      payload = <<0x80, 0x00>>
      refute P.parse_exception(payload)
    end
  end

  describe "parse_any_string_reply/1" do
    test "extracts string from any(string) reply" do
      # Reply: LONGHEADER, any body: TC_STRING (12) + encoded string
      payload = <<0x80, 12>> <> P.enc_str("25.8.1.1")
      assert P.parse_any_string_reply(payload) == {:ok, "25.8.1.1"}
    end

    test "returns error for exception reply" do
      payload = <<0x80 ||| 0x20, 19, 0::16>> <> P.enc_str("some error")
      assert {:error, "some error"} = P.parse_any_string_reply(payload)
    end
  end

  describe "interface OID cache" do
    setup do
      previous = Process.get(:urp_oid_cache)
      Process.delete(:urp_oid_cache)

      on_exit(fn ->
        if previous,
          do: Process.put(:urp_oid_cache, previous),
          else: Process.delete(:urp_oid_cache)
      end)
    end

    test "stores and resolves cached interface references" do
      assert P.parse_interface_reply(<<0x80>> <> P.enc_str("document-1") <> <<7::16>>) ==
               {:ok, "document-1"}

      assert P.parse_interface_reply(<<0x80>> <> P.enc_str("") <> <<7::16>>) ==
               {:ok, "document-1"}
    end

    test "reports an unknown cached interface reference" do
      assert P.parse_interface_reply(<<0x80>> <> P.enc_str("") <> <<9::16>>) ==
               {:error, "unknown cached OID index 9"}
    end
  end

  describe "parse_string_sequence_reply/1" do
    test "parses empty sequence" do
      payload = <<0x80, 0>>
      assert P.parse_string_sequence_reply(payload) == {:ok, []}
    end

    test "parses sequence with multiple strings" do
      payload = <<0x80>> <> <<2>> <> P.enc_str("foo") <> P.enc_str("bar")
      assert P.parse_string_sequence_reply(payload) == {:ok, ["foo", "bar"]}
    end

    test "parses sequence with long count encoding" do
      # Count >= 255 uses 0xFF + 4-byte uint32
      payload = <<0x80, 0xFF, 2::32>> <> P.enc_str("a") <> P.enc_str("b")
      assert P.parse_string_sequence_reply(payload) == {:ok, ["a", "b"]}
    end

    test "returns error for exception reply" do
      payload = <<0x80 ||| 0x20, 19, 0::16>> <> P.enc_str("some error")
      assert {:error, "some error"} = P.parse_string_sequence_reply(payload)
    end
  end

  describe "enc_str/1 and dec_str/1" do
    test "short string roundtrip" do
      assert {s, ""} = P.dec_str(P.enc_str("hello"))
      assert s == "hello"
    end

    test "empty string" do
      assert {s, ""} = P.dec_str(P.enc_str(""))
      assert s == ""
    end

    test "254-byte string uses 1-byte length" do
      s = String.duplicate("x", 254)
      <<len, _::binary>> = P.enc_str(s)
      assert len == 254
    end

    test "255-byte string uses 5-byte length" do
      s = String.duplicate("x", 255)
      <<0xFF, len::32, _::binary>> = P.enc_str(s)
      assert len == 255
    end

    test "decodes with trailing data" do
      encoded = P.enc_str("hello") <> "extra"
      assert {"hello", "extra"} = P.dec_str(encoded)
    end
  end

  describe "enc_count/1" do
    test "uses the compact form through 254" do
      assert P.enc_count(0) == <<0>>
      assert P.enc_count(254) == <<254>>
    end

    test "uses the extended form from 255" do
      assert P.enc_count(255) == <<0xFF, 255::32>>
      assert P.enc_count(65_536) == <<0xFF, 65_536::32>>
    end
  end

  describe "request/2" do
    test "minimal request — no type, oid, tid" do
      header = P.request(5)
      # LONGHEADER | REQUEST, func_id=5
      assert <<0xC0, 5>> = header
    end

    test "with new type" do
      header = P.request(0, type: {:new, "com.sun.star.uno.XInterface", 1})
      <<flags, 0, tc, cache::16, rest::binary>> = header
      # NEWTYPE
      assert (flags &&& 0x20) != 0
      # tc_interface | tc_new
      assert tc == (22 ||| 0x80)
      assert cache == 1
      {"com.sun.star.uno.XInterface", ""} = P.dec_str(rest)
    end

    test "with cached type" do
      header = P.request(0, type: {:cached, 3})
      <<flags, 0, tc, cache::16>> = header
      assert (flags &&& 0x20) != 0
      assert tc == 22
      assert cache == 3
    end
  end
end
