defmodule URP.PoolTest do
  use ExUnit.Case, async: true

  # Real OID observed in production when soffice aborted mid-conversion.
  @stale_oid "57ee30e3f490;gcc3[0];46d08adf17bf43b189511ea4ed49b46f"

  describe "checkout_outcome/4" do
    test "keeps the connection when a sink consumed the output" do
      assert URP.Pool.checkout_outcome(:ok, nil, nil, false) == {:ok, :reuse}
    end

    test "wraps the output bytes when no sink consumed them" do
      assert URP.Pool.checkout_outcome("%PDF-1.7", nil, nil, false) ==
               {{:ok, "%PDF-1.7"}, :reuse}
    end

    test "discards the connection after stream input even on success" do
      assert URP.Pool.checkout_outcome(:ok, nil, nil, true) == {:ok, :discard}
    end

    test "returns the result but discards the connection when only cleanup failed" do
      assert URP.Pool.checkout_outcome(:ok, nil, "close failed", false) == {:ok, :discard}
    end

    test "reports the error when the conversion produced nothing" do
      assert URP.Pool.checkout_outcome(nil, "connection closed", "connection closed", false) ==
               {{:error, "connection closed"}, :discard}
    end

    test "reports the error when a failed conversion left a stale OID in the reply" do
      assert URP.Pool.checkout_outcome(
               @stale_oid,
               "connection closed",
               "connection closed",
               false
             ) ==
               {{:error, "connection closed"}, :discard}
    end

    test "reports the error when a failed conversion left stale bytes in the reply" do
      assert URP.Pool.checkout_outcome(<<0x80, 0, 0, 0, 0>>, "timeout", "timeout", true) ==
               {{:error, "timeout"}, :discard}
    end
  end
end
