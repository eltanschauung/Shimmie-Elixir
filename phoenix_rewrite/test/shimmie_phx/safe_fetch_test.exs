defmodule ShimmiePhoenix.SafeFetchTest do
  use ExUnit.Case, async: true
  alias ShimmiePhoenix.SafeFetch

  test "destination resolution rejects mixed/public-private DNS and unsafe URL forms" do
    public = fn _ -> {:ok, [{8, 8, 8, 8}]} end
    mixed = fn _ -> {:ok, [{8, 8, 8, 8}, {127, 0, 0, 1}]} end
    assert {:error, :invalid_url} = SafeFetch.destination("https://example.test/file", mixed)

    assert {:ok, %{host: "example.test", address: "8.8.8.8", url: "https://example.test/file"}} =
             SafeFetch.destination("https://example.test/file#fragment", public)

    for url <- [
          "file:///etc/passwd",
          "http://user:pass@example.test/",
          "http://example.test:22/",
          "http://example.test/\r\nHeader:bad",
          "http://[::1]/"
        ] do
      assert {:error, :invalid_url} = SafeFetch.destination(url, public)
    end
  end

  test "special-purpose and transition addresses are not valid destinations" do
    for address <- [
          {127, 0, 0, 1},
          {10, 1, 2, 3},
          {169, 254, 169, 254},
          {100, 64, 0, 1},
          {192, 168, 1, 1},
          {198, 18, 0, 1},
          {224, 1, 1, 1},
          {0, 0, 0, 0, 0, 65535, 0x7F00, 1},
          {0x2002, 0x7F00, 1, 0, 0, 0, 0, 1},
          {0xFC00, 0, 0, 0, 0, 0, 0, 1}
        ] do
      refute SafeFetch.public_address?(address)
    end

    assert SafeFetch.public_address?({8, 8, 8, 8})
    assert SafeFetch.public_address?({0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111})
  end
end
