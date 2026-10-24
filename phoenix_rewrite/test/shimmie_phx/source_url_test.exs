defmodule ShimmiePhoenix.SourceURLTest do
  use ExUnit.Case, async: true
  alias ShimmiePhoenix.SourceURL

  test "only complete HTTP(S) URLs become links" do
    assert SourceURL.href(" https://example.org/image?q=a&x=b ") ==
             "https://example.org/image?q=a&x=b"

    assert SourceURL.href("HTTP://example.org/image") == "http://example.org/image"
    assert SourceURL.normalize("an artist's source") == {:ok, "an artist's source"}
    assert SourceURL.href("an artist's source") == nil
    assert SourceURL.href("//example.org/image") == nil
    assert SourceURL.normalize("") == {:ok, nil}
  end

  test "active schemes, controls, credentials and malformed URLs fail closed" do
    for source <- [
          "javascript:void(0)",
          "JaVaScRiPt:void(0)",
          "data:text/html,test",
          "https://example.org/\nimage",
          "java\tscript:void(0)",
          "https://",
          "https://user:secret@example.org/",
          "https://example.org/a b",
          "https://example.org\\image",
          "https://example.org:99999/"
        ] do
      assert {:error, :invalid_source} = SourceURL.normalize(source)
      assert SourceURL.href(source) == nil
    end
  end
end
