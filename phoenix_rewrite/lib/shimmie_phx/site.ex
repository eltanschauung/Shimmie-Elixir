defmodule ShimmiePhoenix.Site do
  @moduledoc "Site paths, explicit PostgreSQL configuration and preserved native settings."
  alias ShimmiePhoenix.{DatabaseURL, NativeConfig}

  def legacy_root, do: Application.get_env(:shimmie_phx, :legacy_root)
  def database_url_source, do: if(DatabaseURL.explicit_url(), do: :env_url, else: :none)
  def database_url, do: DatabaseURL.explicit_url()
  def redacted_database_url, do: DatabaseURL.redact(database_url())
  def secret, do: NativeConfig.secret() || "shimmie"
  def warehouse_splits, do: NativeConfig.get("warehouse_splits", 1)
end
