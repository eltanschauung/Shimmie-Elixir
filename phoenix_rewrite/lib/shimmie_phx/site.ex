defmodule ShimmiePhoenix.Site do
  @moduledoc """
  Compatibility helpers for reading the legacy Shimmie2 deployment layout.
  """

  @define_re_template ~r/define\(\s*['"]%KEY%['"]\s*,\s*([^)]+)\)/
  @cache_table :shimmie_legacy_cache
  alias ShimmiePhoenix.Cache
  alias ShimmiePhoenix.DatabaseURL

  def legacy_root, do: Application.get_env(:shimmie_phx, :legacy_root)
  def legacy_assets_dir, do: Application.get_env(:shimmie_phx, :legacy_assets_dir)
  def legacy_config_path, do: Application.get_env(:shimmie_phx, :legacy_config_path)

  def database_url_source do
    cond do
      System.get_env("SHIMMIE_DATABASE_URL") -> :env_url
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

  def sqlite_db_path do
    case legacy_dsn() do
      "sqlite:" <> rest ->
        rel_or_abs = String.trim(rest)

        cond do
          rel_or_abs == "" -> nil
          Path.type(rel_or_abs) == :absolute -> rel_or_abs
          true -> Path.expand(rel_or_abs, legacy_root())
        end

      _ ->
        nil
    end
  end

  def database_url do
    System.get_env("SHIMMIE_DATABASE_URL") || legacy_dsn_to_ecto_url(legacy_dsn())
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

  defp unquote_if_quoted("'" <> rest), do: String.trim_trailing(rest, "'")
  defp unquote_if_quoted("\"" <> rest), do: String.trim_trailing(rest, "\"")
  defp unquote_if_quoted(value), do: value
end
