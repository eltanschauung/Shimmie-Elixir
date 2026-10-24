defmodule ShimmiePhoenix.SourceURL do
  @moduledoc "Validation shared by untrusted source writes and historical source links."

  @controls ~r/[\x00-\x1f\x7f]/

  def normalize(nil), do: {:ok, nil}

  def normalize(value) when is_binary(value) do
    cond do
      not String.valid?(value) or byte_size(value) > 8_192 -> {:error, :invalid_source}
      Regex.match?(@controls, value) -> {:error, :invalid_source}
      true -> normalize_trimmed(String.trim(value))
    end
  end

  def normalize(_), do: {:error, :invalid_source}

  def href(value) do
    with {:ok, text} when is_binary(text) <- normalize(value),
         %URI{scheme: scheme} <- URI.parse(text),
         true <- scheme in ["http", "https"] do
      text
    else
      _ -> nil
    end
  end

  defp normalize_trimmed(""), do: {:ok, nil}

  defp normalize_trimmed(value) do
    if Regex.match?(~r/\A[a-zA-Z][a-zA-Z0-9+.-]*:/, value) do
      normalize_url(value)
    else
      {:ok, value}
    end
  end

  defp normalize_url(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, port: port} = uri}
      when is_binary(host) and host != "" and port in 1..65_535 ->
        if String.downcase(scheme) in ["http", "https"] and
             not String.contains?(value, [" ", "\\"]) do
          {:ok, URI.to_string(%{uri | scheme: String.downcase(scheme)})}
        else
          {:error, :invalid_source}
        end

      _ ->
        {:error, :invalid_source}
    end
  end
end
