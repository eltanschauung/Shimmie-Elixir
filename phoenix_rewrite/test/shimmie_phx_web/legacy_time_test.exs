defmodule ShimmiePhoenixWeb.LegacyTimeTest do
  use ExUnit.Case, async: true

  alias ShimmiePhoenixWeb.LegacyTime

  test "formats legacy naive timestamps for display" do
    assert LegacyTime.format_post_date(~N[2026-01-01 13:00:00]) == "January 1, 2026; 13:00"
  end

  test "emits absolute UTC datetime attributes for timeago localization" do
    assert LegacyTime.datetime_attr(~N[2026-01-01 13:00:00]) == "2026-01-01T13:00:00Z"
    assert LegacyTime.datetime_attr("2026-01-01 13:00:00.000000") == "2026-01-01T13:00:00Z"
  end
end
