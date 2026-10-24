defmodule ShimmiePhoenix.SafePathTest do
  use ExUnit.Case, async: true
  alias ShimmiePhoenix.SafePath

  test "trusted state root links work, descendant directory/file links do not" do
    root = Path.join(System.tmp_dir!(), "safe_path_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "state/real"))
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "state/real/file"), "fixture")
    File.ln_s!(Path.join(root, "state"), Path.join(root, "data"))
    assert {:ok, _} = SafePath.regular_file(Path.join(root, "data"), "real/file")
    File.ln_s!(Path.join(root, "state/real"), Path.join(root, "state/linked"))
    File.ln_s!(Path.join(root, "state/real/file"), Path.join(root, "state/link"))
    assert {:error, _} = SafePath.regular_file(Path.join(root, "data"), "linked/file")
    assert {:error, _} = SafePath.regular_file(Path.join(root, "data"), "link")
    assert {:error, _} = SafePath.regular_file(Path.join(root, "data"), "../state/real/file")
  end
end
