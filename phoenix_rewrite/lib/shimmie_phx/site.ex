defmodule ShimmiePhoenix.Site do
  @moduledoc "Compatibility helpers for reading the legacy Shimmie2 deployment layout.\r\n"

  @define_re_template ~r/define\(\s*['"]%KEY%['"]\s*,\s*([^)]+)\)/
  @cache_table :shimmie_legacy_cache
  alias ShimmiePhoenix.Cache
  alias ShimmiePhoenix.DatabaseURL

  def legacy_root do
    Application.get_env(:shimmie_phx, :legacy_root)
  end

  def legacy_assets_dir do
    Application.get_env(:shimmie_phx, :legacy_assets_dir)
  end

  def legacy_config_path do
    Application.get_env(:shimmie_phx, :legacy_config_path)
  end

  def database_url_source do
    cond do
      DatabaseURL.explicit_url() -> :env_url
      System.get_env("SHIMMIE_LEGACY_DSN") -> :env_dsn
      has_php_config?() -> :php_config
      true -> :none
    end
  end

  def legacy_dsn do
    cond do
      System.get_env("SHIMMIE_LEGACY_DSN") ->
        System.get_env("SHIMMIE_LEGACY_DSN")

      has_php_config?() ->
        php_constant("DATABASE_DSN")

      true ->
        nil
    end
  end

  def secret do
    php_constant("SECRET") || legacy_dsn() || "shimmie"
  end

  def warehouse_splits do
    value =
      case php_constant("WH_SPLITS") do
        nil -> nil
        v -> String.trim(v)
      end

    case Integer.parse(value || "") do
      {n, ""} when n >= 0 -> n
      _ -> 1
    end
  end

  def database_url do
    DatabaseURL.resolve(legacy_dsn())
  end

  def redacted_database_url do
    DatabaseURL.redact(database_url())
  end

  defdelegate legacy_dsn_to_ecto_url(dsn), to: DatabaseURL, as: :from_legacy_dsn

  defp php_constant(key) do
    with {:ok, content} <- php_config_content() do
      regex = constant_regex(key)

      case Regex.run(regex, content) do
        [_, value] ->
          normalize_php_value(value)

        _ ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp has_php_config? do
    match?({:ok, _}, php_config_content())
  end

  defp php_config_content do
    path = legacy_config_path()

    cond do
      not is_binary(path) or path == "" ->
        {:error, :invalid_path}

      true ->
        case File.stat(path) do
          {:ok, %{mtime: mtime}} ->
            key = {:php_config_content, path}

            case Cache.lookup(@cache_table, key) do
              [{^key, ^mtime, content}] ->
                {:ok, content}

              _ ->
                case File.read(path) do
                  {:ok, content} ->
                    Cache.insert(@cache_table, {key, mtime, content})
                    {:ok, content}

                  error ->
                    error
                end
            end

          error ->
            error
        end
    end
  end

  defp constant_regex(key) do
    source =
      @define_re_template
      |> Regex.source()
      |> String.replace("%KEY%", Regex.escape(key))

    Regex.compile!(source)
  end

  defp normalize_php_value(value) do
    value
    |> String.trim()
    |> String.trim_trailing(";")
    |> String.trim()
    |> unquote_if_quoted()
  end

  defp unquote_if_quoted("'" <> rest) do
    String.trim_trailing(rest, "'")
  end

  defp unquote_if_quoted("\"" <> rest) do
    String.trim_trailing(rest, "\"")
  end

  defp unquote_if_quoted(value) do
    value
  end
end
