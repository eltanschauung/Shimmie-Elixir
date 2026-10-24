defmodule ShimmiePhoenix.Site.TelegramAlertsTest do
  use ShimmiePhoenix.DataCase, async: false
  alias ShimmiePhoenix.Site.{Store, TelegramAlerts}
  alias ShimmiePhoenix.SiteSchemaHelper

  test "notification workers are supervised and have a finite concurrency budget" do
    supervisor = ShimmiePhoenix.NotificationSupervisor

    workers =
      for _ <- 1..16 do
        {:ok, pid} =
          Task.Supervisor.start_child(supervisor, fn ->
            receive do
              :finish -> :ok
            end
          end)

        pid
      end

    on_exit(fn -> Enum.each(workers, &Task.Supervisor.terminate_child(supervisor, &1)) end)
    assert {:error, :max_children} = Task.Supervisor.start_child(supervisor, fn -> :ok end)
    assert length(Task.Supervisor.children(supervisor)) == 16
  end

  test "disabled notifications remain no-op and do not contact external services" do
    SiteSchemaHelper.ensure_legacy_tables!()
    SiteSchemaHelper.reset_legacy_tables!()
    assert :ok = Store.put_config("telegram_alerts_enabled", "0")
    assert :ok = TelegramAlerts.notify_comment_added(101, %{name: "test"}, "test")
    assert :ok = TelegramAlerts.notify_post_uploaded(101, %{name: "test"}, ["test"], true)
    assert Task.Supervisor.children(ShimmiePhoenix.NotificationSupervisor) == []
  end
end
