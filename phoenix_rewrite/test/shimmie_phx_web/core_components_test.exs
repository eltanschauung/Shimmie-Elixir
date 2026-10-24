defmodule ShimmiePhoenixWeb.CoreComponentsTest do
  use ExUnit.Case, async: true
  alias ShimmiePhoenixWeb.CoreComponents

  test "validation messages retain interpolation after the Gettext upgrade" do
    Gettext.put_locale(ShimmiePhoenixWeb.Gettext, "en")
    assert CoreComponents.translate_error({"can't be blank", []}) == "can't be blank"

    assert CoreComponents.translate_error({"must be at least %{count} characters", [count: 3]}) ==
             "must be at least 3 characters"
  end
end
