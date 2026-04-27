defmodule ShimmiePhoenix.Site.Captcha do
  @moduledoc """
  Server-side reCAPTCHA verification for legacy forms.
  """

  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.Site.Users

  @verify_url 'https://www.google.com/recaptcha/api/siteverify'

  def verify_for_comment(actor, params, remote_ip) when is_map(params) do
    if anonymous_actor?(actor) and config_bool("comment_captcha", false) do
      verify(params["g-recaptcha-response"], remote_ip)
    else
      :ok
    end
  end

  def verify_for_comment(_actor, _params, _remote_ip), do: :ok

  def verify_for_signup(params, remote_ip) when is_map(params) do
    if recaptcha_configured?() do
      verify(params["g-recaptcha-response"], remote_ip)
    else
      :ok
    end
  end

  def verify_for_signup(_params, _remote_ip), do: :ok

  defp verify(response_token, remote_ip) do
    secret = Store.get_config("api_recaptcha_privkey", "") |> to_string() |> String.trim()
    token = response_token |> to_string() |> String.trim()

    cond do
      secret == "" ->
        :ok

      token == "" ->
        {:error, :captcha_failed}

      true ->
        do_verify(secret, token, remote_ip)
    end
  end

  defp do_verify(secret, token, remote_ip) do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)

    body =
      URI.encode_query(%{
        "secret" => secret,
        "response" => token,
        "remoteip" => to_string(remote_ip || "")
      })

    request = {
      @verify_url,
      [{'content-type', 'application/x-www-form-urlencoded'}],
      'application/x-www-form-urlencoded',
      String.to_charlist(body)
    }

    case :httpc.request(:post, request, [timeout: 10_000, connect_timeout: 5_000],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _headers, response_body}} when status in 200..299 ->
        case Jason.decode(response_body) do
          {:ok, %{"success" => true}} -> :ok
          _ -> {:error, :captcha_failed}
        end

      _ ->
        {:error, :captcha_failed}
    end
  end

  defp recaptcha_configured? do
    Store.get_config("api_recaptcha_pubkey", "") |> to_string() |> String.trim() != "" or
      Store.get_config("api_recaptcha_privkey", "") |> to_string() |> String.trim() != ""
  end

  defp config_bool(key, default) do
    case Store.get_config(key, if(default, do: "Y", else: "N"))
         |> to_string()
         |> String.downcase() do
      value when value in ["1", "y", "yes", "true", "on"] -> true
      value when value in ["0", "n", "no", "false", "off"] -> false
      _ -> default
    end
  end

  defp anonymous_actor?(nil), do: true

  defp anonymous_actor?(%{id: id, class: class}) do
    id == Users.anonymous_id() or normalize_class(class) == "anonymous"
  end

  defp anonymous_actor?(_), do: true

  defp normalize_class(class) do
    class
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end
end
