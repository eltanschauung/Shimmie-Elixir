defmodule ShimmiePhoenix.NativeMetadataTest do
  use ShimmiePhoenix.DataCase, async: false
  alias ShimmiePhoenix.Site.Pages

  setup do
    root = Path.join(System.tmp_dir!(), "native_metadata_#{System.unique_integer([:positive])}")
    old_root = Application.get_env(:shimmie_phx, :legacy_root)
    old_config = Application.get_env(:shimmie_phx, :site_config_path)
    File.mkdir_p!(Path.join(root, "ext/example"))
    File.mkdir_p!(Path.join(root, "themes/example"))
    config = Path.join(root, "site.json")
    File.write!(config, Jason.encode!(%{"enabled_extensions" => ["example"]}))
    Application.put_env(:shimmie_phx, :legacy_root, root)
    Application.put_env(:shimmie_phx, :site_config_path, config)

    on_exit(fn ->
      Application.put_env(:shimmie_phx, :legacy_root, old_root)
      Application.put_env(:shimmie_phx, :site_config_path, old_config)
      ShimmiePhoenix.Cache.clear()
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "extension names and enablement use JSON metadata rather than PHP", %{root: root} do
    File.write!(
      Path.join(root, "ext/example/extension.json"),
      Jason.encode!(%{"name" => "Example Feature", "description" => "Native metadata"})
    )

    assert %{name: "Example Feature", description: "Native metadata", enabled?: true} =
             Enum.find(Pages.extension_manager_rows(), &(&1.key == "example"))

    assert Pages.enabled_extension_keys() == ["example"]
  end

  test "theme discovery uses a native manifest without PHP sentinel files", %{root: root} do
    File.write!(
      Path.join(root, "themes/example/theme.json"),
      Jason.encode!(%{"name" => "Example"})
    )

    assert Pages.available_themes() == [%{value: "example", label: "Example"}]
  end
end
