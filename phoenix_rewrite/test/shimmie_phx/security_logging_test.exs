defmodule ShimmiePhoenix.SecurityLoggingTest do
  use ShimmiePhoenix.DataCase, async: false
  import ExUnit.CaptureLog
  alias ShimmiePhoenix.Site.Users
  alias ShimmiePhoenix.SiteSchemaHelper

  test "actual credential names are filtered recursively from request diagnostics" do
    supplied = %{
      "pass" => "test-old",
      "pass1" => "test-new",
      "pass2" => "test-new",
      "nested" => %{
        "g-recaptcha-response" => "test-captcha",
        "api_recaptcha_privkey" => "test-key",
        "telegram_alerts_bot_token" => "test-token"
      },
      "id" => "5"
    }

    filtered = Phoenix.Logger.filter_values(supplied)
    for key <- ["pass", "pass1", "pass2"], do: assert(filtered[key] == "[FILTERED]")
    assert Enum.all?(filtered["nested"], fn {_key, value} -> value == "[FILTERED]" end)

    log =
      capture_log(fn ->
        require Logger
        Logger.warning("params=#{inspect(filtered)}")
      end)

    for value <- ["test-old", "test-new", "test-captcha", "test-key", "test-token"],
        do: refute(log =~ value)

    assert filtered["id"] == "5"
  end

  test "login diagnostics do not interpolate untrusted account names" do
    SiteSchemaHelper.ensure_legacy_tables!()
    SiteSchemaHelper.reset_legacy_tables!()

    log =
      capture_log(fn ->
        assert {:error, :invalid_credentials} =
                 Users.login("unknown\nforged-log-marker", "test-only", "192.0.2.4")
      end)

    assert log =~ "auth.login failure"
    refute log =~ "forged-log-marker"
    refute log =~ "test-only"
  end
end
