defmodule PhoenixKitAI.Providers.HTTPTest do
  @moduledoc """
  The image-fetch host policy on literal addresses (no DNS involved):
  internal, reserved and multicast addresses are refused however they are
  spelled, including IPv6 forms that embed an IPv4 address.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitAI.Providers.HTTP

  describe "safe_url?/1" do
    test "allows public addresses, including a NAT64 form of one" do
      for url <- [
            "https://8.8.8.8/a.png",
            "http://[2001:4860:4860::8888]/a.png",
            "http://[64:ff9b::808:808]/a.png"
          ] do
        assert HTTP.safe_url?(url), url
      end
    end

    test "refuses internal, reserved and multicast IPv4 addresses" do
      for url <- [
            "http://127.0.0.1/x",
            "http://10.0.0.5/x",
            "http://169.254.169.254/x",
            "http://100.64.0.1/x",
            "http://192.0.0.170/x",
            "http://198.18.0.1/x",
            "http://224.0.0.251/x",
            "http://240.0.0.1/x",
            "http://255.255.255.255/x"
          ] do
        refute HTTP.safe_url?(url), url
      end
    end

    test "judges IPv6 forms that embed an IPv4 address by that address" do
      for url <- [
            # IPv4-mapped, IPv4-translated and IPv4-compatible 127.0.0.1 / 10.0.0.1
            "http://[::ffff:127.0.0.1]/x",
            "http://[::ffff:0:a00:1]/x",
            "http://[::a00:1]/x",
            "http://[::1]/x",
            # NAT64 and 6to4 of 169.254.169.254
            "http://[64:ff9b::a9fe:a9fe]/x",
            "http://[2002:a9fe:a9fe::1]/x"
          ] do
        refute HTTP.safe_url?(url), url
      end
    end

    test "refuses local-use NAT64, unique-local, link-local and multicast IPv6" do
      for url <- [
            "http://[64:ff9b:1::a00:1]/x",
            "http://[fd00::1]/x",
            "http://[fe80::1]/x",
            "http://[ff02::1]/x"
          ] do
        refute HTTP.safe_url?(url), url
      end
    end
  end
end
