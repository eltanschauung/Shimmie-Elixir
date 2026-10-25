defmodule ShimmiePhoenix.DistributionAssetsTest do
  use ExUnit.Case, async: false

  test "application assets no longer include executable PHP files" do
    app = Path.expand("../..", __DIR__)
    root = Path.expand("..", app)

    for directory <- [
          Path.join(app, "priv/static"),
          Path.join(root, "ext"),
          Path.join(root, "themes")
        ] do
      assert Path.wildcard(Path.join(directory, "**/*.php")) == []
    end

    refute File.exists?(Path.join(root, "index.php"))
  end
end
