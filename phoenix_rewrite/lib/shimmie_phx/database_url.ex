defmodule ShimmiePhoenix.DatabaseURL do
  @moduledoc "Shared, side-effect-free legacy PostgreSQL DSN conversion and diagnostic redaction."

  def from_legacy_dsn("pgsql:" <> options) do
    params =
      options
      |> String.split(";", trim: true)
      |> Enum.reduce(%{}, fn option, acc ->
        case String.split(option, "=", parts: 2) do
          [key, value] -> Map.put(acc, String.trim(key), value)
          _ -> acc
        end
      end)

    user = encode(Map.get(params, "user", "postgres"))
    password = Map.get(params, "password", "")
    userinfo = if password == "", do: user, else: user <> ":" <> encode(password)
    host = Map.get(params, "host", "localhost")

    host =
      if String.contains?(host, ":") and not String.starts_with?(host, "["),
        do: "[#{host}]",
        else: host

    port = Map.get(params, "port", "")
    authority = if port == "", do: host, else: host <> ":" <> port
    database = encode(Map.get(params, "dbname", "shimmie"))
    "ecto://#{userinfo}@#{authority}/#{database}"
  end

  def from_legacy_dsn(_), do: nil

  def redact(nil), do: nil

  def redact(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{userinfo: userinfo} = uri} when is_binary(userinfo) ->
        user = userinfo |> String.split(":", parts: 2) |> hd()
        URI.to_string(%{uri | userinfo: user <> ":******", query: nil, fragment: nil})

      {:ok, uri} ->
        URI.to_string(%{uri | query: nil, fragment: nil})

      {:error, _} ->
        "[invalid database URL]"
    end
  end

  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
