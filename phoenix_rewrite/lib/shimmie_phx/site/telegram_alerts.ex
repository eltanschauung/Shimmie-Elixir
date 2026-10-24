defmodule ShimmiePhoenix.Site.TelegramAlerts do
  @moduledoc """
  Telegram channel notifications for key board events.
  """

  require Logger

  alias ShimmiePhoenix.Site.Store

  @true_values MapSet.new(["1", "true", "yes", "on", "y", "t"])

  def notify_post_uploaded(image_id, actor, tags, approved?)
      when is_integer(image_id) and image_id > 0 and is_list(tags) and is_boolean(approved?) do
    if event_enabled?(:upload) do
      status = if approved?, do: "approved", else: "pending approval"

      lines = [
        "New post uploaded",
        "Post: #{post_url(image_id)}",
        "ID: #{image_id}",
        "By: #{actor_name(actor)}",
        "Status: #{status}",
        maybe_tags_line(tags)
      ]

      dispatch_async(lines)
    end

    :ok
  end

  def notify_post_uploaded(_image_id, _actor, _tags, _approved?), do: :ok

  def notify_post_approved(image_id, actor) when is_integer(image_id) and image_id > 0 do
    if event_enabled?(:approve) do
      lines = [
        "Post approved",
        "Post: #{post_url(image_id)}",
        "ID: #{image_id}",
        "Approved by: #{actor_name(actor)}"
      ]

      dispatch_async(lines)
    end

    :ok
  end

  def notify_post_approved(_image_id, _actor), do: :ok

  def notify_comment_added(image_id, actor, comment)
      when is_integer(image_id) and image_id > 0 and is_binary(comment) do
    if event_enabled?(:comment) do
      lines = [
        "New comment",
        "Post: #{post_url(image_id)}",
        "By: #{actor_name(actor)}",
        "Comment: #{comment_snippet(comment)}"
      ]

      dispatch_async(lines)
    end

    :ok
  end

  def notify_comment_added(_image_id, _actor, _comment), do: :ok

  defp dispatch_async(lines) when is_list(lines) do
    case credentials() do
      {:ok, token, chat_id} ->
        message =
          lines
          |> Enum.reject(&is_nil_or_blank?/1)
          |> Enum.join("\n")

        enqueue(fn -> send_message(token, chat_id, message) end)
        :ok

      _ ->
        :ok
    end
  end

  defp enqueue(fun) do
    case Task.Supervisor.start_child(ShimmiePhoenix.NotificationSupervisor, fun) do
      {:ok, _pid} -> :ok
      {:error, _reason} -> dropped_notification()
    end
  catch
    :exit, _reason -> dropped_notification()
  end

  defp dropped_notification do
    :telemetry.execute([:shimmie_phx, :notification, :dropped], %{count: 1}, %{})
    :ok
  end

  defp send_message(token, chat_id, message) do
    _ = :inets.start()
    _ = :ssl.start()

    encoded =
      URI.encode_query(%{
        "chat_id" => chat_id,
        "text" => message,
        "disable_web_page_preview" => "true"
      })

    url = "https://api.telegram.org/bot#{token}/sendMessage"

    request = {
      String.to_charlist(url),
      [{'content-type', 'application/x-www-form-urlencoded'}],
      'application/x-www-form-urlencoded',
      String.to_charlist(encoded)
    }

    http_options = [timeout: 5_000, connect_timeout: 5_000, ssl: ssl_options()]

    case :httpc.request(:post, request, http_options, body_format: :binary) do
      {:ok, {{_, status, _}, _headers, body}} when status in 200..299 ->
        validate_telegram_response(body)

      {:ok, {{_, status, _}, _headers, _body}} ->
        Logger.warning("telegram_alerts.send failed status=#{status}")
        :error

      {:error, _reason} ->
        Logger.warning("telegram_alerts.send failed")
        :error
    end
  rescue
    _exception ->
      Logger.warning("telegram_alerts.send raised")
      :error
  catch
    _kind, _reason ->
      Logger.warning("telegram_alerts.send threw")
      :error
  end

  defp ssl_options do
    hostname_check =
      if function_exported?(:public_key, :pkix_verify_hostname_match_fun, 1) do
        [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      else
        []
      end

    base = [
      verify: :verify_peer,
      cacerts: ca_certs(),
      server_name_indication: 'api.telegram.org',
      depth: 3
    ]

    if hostname_check == [] do
      base
    else
      Keyword.put(base, :customize_hostname_check, hostname_check)
    end
  end

  defp ca_certs do
    if function_exported?(:public_key, :cacerts_get, 0) do
      :public_key.cacerts_get()
    else
      []
    end
  end

  defp validate_telegram_response(body) do
    case Jason.decode(to_string(body || "")) do
      {:ok, %{"ok" => true}} ->
        :ok

      {:ok, _payload} ->
        Logger.warning("telegram_alerts.send rejected")
        :error

      {:error, _reason} ->
        Logger.warning("telegram_alerts.send invalid response")
        :error
    end
  end

  defp credentials do
    token = read_secret("SHIMMIE_TELEGRAM_BOT_TOKEN", "telegram_alerts_bot_token")
    chat_id = read_secret("SHIMMIE_TELEGRAM_CHAT_ID", "telegram_alerts_chat_id")

    if enabled?() and token != "" and chat_id != "" do
      {:ok, token, chat_id}
    else
      :error
    end
  end

  defp enabled? do
    config_bool("telegram_alerts_enabled", false)
  end

  defp event_enabled?(:upload), do: enabled?() and config_bool("telegram_alerts_on_upload", true)

  defp event_enabled?(:approve),
    do: enabled?() and config_bool("telegram_alerts_on_approve", true)

  defp event_enabled?(:comment),
    do: enabled?() and config_bool("telegram_alerts_on_comment", true)

  defp event_enabled?(_), do: false

  defp actor_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp actor_name(_), do: "Anonymous"

  defp maybe_tags_line(tags) do
    rendered =
      tags
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(20)
      |> Enum.join(" ")

    if rendered == "", do: nil, else: "Tags: #{rendered}"
  end

  defp comment_snippet(comment) do
    comment
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, 220)
  end

  defp post_url(image_id) do
    path = "/post/view/#{image_id}"
    base = base_url()
    if base == "", do: path, else: base <> path
  end

  defp base_url do
    env =
      System.get_env("SHIMMIE_TELEGRAM_BASE_URL")
      |> to_string()
      |> String.trim()

    config = Store.get_config("telegram_alerts_base_url", "") |> to_string() |> String.trim()

    [env, config]
    |> Enum.find("", &(&1 != ""))
    |> String.trim_trailing("/")
  end

  defp config_bool(name, default) do
    fallback = if(default, do: "1", else: "0")

    Store.get_config(name, fallback)
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> then(&MapSet.member?(@true_values, &1))
  end

  defp read_secret(env_name, config_name) do
    env =
      System.get_env(env_name)
      |> to_string()
      |> String.trim()

    config =
      Store.get_config(config_name, "")
      |> to_string()
      |> String.trim()

    [env, config]
    |> Enum.find("", &(&1 != ""))
  end

  defp is_nil_or_blank?(nil), do: true
  defp is_nil_or_blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp is_nil_or_blank?(_), do: false
end
