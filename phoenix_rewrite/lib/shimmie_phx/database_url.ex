defmodule ShimmiePhoenix.DatabaseURL do
  @moduledoc "Explicit PostgreSQL URL selection and credential-safe diagnostic redaction."

  def explicit_url do
    case System.get_env("DATABASE_URL") || System.get_env("SHIMMIE_DATABASE_URL") do
      nil ->
        nil

      url ->
        case URI.new(url) do
          {:ok, %{scheme: scheme}} when scheme in ["ecto", "postgres", "postgresql"] -> url
          _ -> raise ArgumentError, "A valid PostgreSQL DATABASE_URL is required"
        end
    end
  end

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
end
