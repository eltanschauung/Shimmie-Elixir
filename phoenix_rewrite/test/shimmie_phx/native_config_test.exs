defmodule ShimmiePhoenix.NativeConfigTest do
  use ExUnit.Case, async: false
  alias ShimmiePhoenix.NativeConfig

  setup do
    root = Path.join(System.tmp_dir!(), "native_config_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{config_path: Path.join(root, "site.json")}
  end

  test "native JSON preserves secret bytes, storage layout and extension selections", %{
    config_path: file
  } do
    values = %{
      "secret" => "synthetic:stable/secret",
      "warehouse_splits" => 2,
      "enabled_extensions" => ["ipban", "tag_history"]
    }

    File.write!(file, Jason.encode!(values))
    assert NativeConfig.read!(file) == values
  end

  test "malformed or executable-looking configuration fails without exposing contents", %{
    config_path: file
  } do
    File.write!(file, "<?php secret_private_fixture();")

    assert_raise ArgumentError, "Invalid native site configuration", fn ->
      NativeConfig.read!(file)
    end
  end

  test "wrong setting types and invalid extension names are rejected" do
    for values <- [
          %{"secret" => 123},
          %{"warehouse_splits" => -1},
          %{"warehouse_splits" => 33},
          %{"enabled_extensions" => "ipban"},
          %{"enabled_extensions" => ["../private"]}
        ] do
      assert_raise ArgumentError, "Invalid native site configuration", fn ->
        NativeConfig.validate!(values)
      end
    end
  end

  test "missing files are optional outside the production secret check and large files are rejected",
       %{config_path: file} do
    assert NativeConfig.read!(file) == %{}
    File.write!(file, String.duplicate("x", 65_537))

    assert_raise ArgumentError, "Invalid native site configuration", fn ->
      NativeConfig.read!(file)
    end
  end
end
