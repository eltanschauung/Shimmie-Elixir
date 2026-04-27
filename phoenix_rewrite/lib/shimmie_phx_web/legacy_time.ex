defmodule ShimmiePhoenixWeb.LegacyTime do
  @moduledoc false

  def format_post_date(value) do
    case legacy_naive_datetime(value) do
      {:ok, dt} -> Calendar.strftime(dt, "%B %-d, %Y; %H:%M")
      :error -> to_string(value || "")
    end
  end

  def datetime_attr(value) do
    case legacy_datetime(value) do
      {:ok, dt} -> dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      :error -> to_string(value || "")
    end
  end

  defp legacy_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp legacy_datetime(value) do
    case legacy_naive_datetime(value) do
      {:ok, dt} -> DateTime.from_naive(dt, "Etc/UTC")
      :error -> :error
    end
  end

  defp legacy_naive_datetime(%NaiveDateTime{} = dt), do: {:ok, dt}
  defp legacy_naive_datetime(%DateTime{} = dt), do: {:ok, DateTime.to_naive(dt)}

  defp legacy_naive_datetime(value) do
    value
    |> to_string()
    |> String.trim()
    |> parse_naive_datetime()
  end

  defp parse_naive_datetime(""), do: :error

  defp parse_naive_datetime(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, dt} ->
        {:ok, dt}

      _ ->
        value
        |> String.replace(" ", "T", global: false)
        |> NaiveDateTime.from_iso8601()
        |> case do
          {:ok, dt} -> {:ok, dt}
          _ -> :error
        end
    end
  end
end
