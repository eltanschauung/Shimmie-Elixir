defmodule ShimmiePhoenix.NativeConfig do
  @moduledoc "Native JSON site settings; never evaluates application or PHP source."
  alias ShimmiePhoenix.Cache

  @cache_table :shimmie_legacy_cache
  @max_bytes 65_536

  def get(key, default \\ nil), do: Map.get(values(), key, default)

  def secret, do: System.get_env("SHIMMIE_SECRET") || get("secret")

  def values do
    path = Application.get_env(:shimmie_phx, :site_config_path)

    if is_binary(path) do
      now = System.monotonic_time(:millisecond)
      key = {:native_config, path}

      case Cache.lookup(@cache_table, key) do
        [{^key, settings, expires}] when expires > now ->
          settings

        _ ->
          settings = read!(path)
          Cache.insert(@cache_table, {key, settings, now + 1_000})
          settings
      end
    else
      %{}
    end
  end

  def read!(path) do
    case File.stat(path) do
      {:error, :enoent} ->
        %{}

      {:ok, %{type: :regular, size: size}} when size <= @max_bytes ->
        with {:ok, body} <- File.read(path),
             {:ok, values} when is_map(values) <- Jason.decode(body) do
          validate!(values)
        else
          _ -> invalid!()
        end

      _ ->
        invalid!()
    end
  end

  def validate!(values) when is_map(values) do
    secret = Map.get(values, "secret")
    splits = Map.get(values, "warehouse_splits", 1)
    extensions = Map.get(values, "enabled_extensions", [])

    unless (is_nil(secret) or (is_binary(secret) and byte_size(secret) > 0)) and
             is_integer(splits) and splits in 0..32 and is_list(extensions) and
             Enum.all?(extensions, &(is_binary(&1) and Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, &1))) do
      invalid!()
    end

    values
  end

  defp invalid!, do: raise(ArgumentError, "Invalid native site configuration")
end
