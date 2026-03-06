defmodule ShimmiePhoenix.Site.Permissions do
  @moduledoc """
  Config-backed permissions nexus for class-based capability checks.
  """

  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.Site.Users

  @rules [
    %{
      id: "upload",
      label: "Upload",
      config_key: "perm_upload",
      default: ["anonymous", "user", "tag-dono", "taggers", "moderator", "admin"]
    },
    %{
      id: "tag_edit",
      label: "Edit Tags",
      config_key: "perm_tag_edit",
      default: ["admin", "taggers", "tag-dono", "moderator"]
    },
    %{
      id: "approve",
      label: "Approve Posts",
      config_key: "perm_approve",
      default: ["admin", "taggers", "tag-dono", "moderator"]
    },
    %{
      id: "comment_create",
      label: "Create Comments",
      config_key: "perm_comment_create",
      default: ["anonymous", "user", "tag-dono", "taggers", "moderator", "admin", "base"]
    },
    %{
      id: "comment_delete",
      label: "Delete Comments",
      config_key: "perm_comment_delete",
      default: ["admin", "tag-dono"]
    },
    %{
      id: "comment_view_ip",
      label: "View Comment IPs",
      config_key: "perm_comment_view_ip",
      default: ["admin"]
    },
    %{
      id: "comment_ban_ip",
      label: "Ban Comment IPs",
      config_key: "perm_comment_ban_ip",
      default: ["admin"]
    }
  ]

  def rules, do: @rules

  def rule(rule_id) when is_atom(rule_id), do: rule(Atom.to_string(rule_id))

  def rule(rule_id) when is_binary(rule_id) do
    Enum.find(@rules, fn %{id: id} -> id == rule_id end)
  end

  def classes_for(rule_id) do
    case rule(rule_id) do
      nil ->
        []

      %{config_key: key, default: defaults} ->
        default_value = Enum.join(defaults, ",")
        parse_classes(Store.get_config(key, default_value), defaults)
    end
  end

  def allowed?(rule_id, actor_or_class) do
    class_name = normalize_class(actor_or_class)
    class_name != "" and class_name in classes_for(rule_id)
  end

  def set_classes(rule_id, raw_value) do
    case rule(rule_id) do
      nil ->
        {:error, :unknown_rule}

      %{config_key: key, default: defaults} ->
        normalized =
          raw_value
          |> parse_classes(defaults)
          |> Enum.join(",")

        Store.put_config(key, normalized)
    end
  end

  def editor_rows do
    Enum.map(@rules, fn rule ->
      classes = classes_for(rule.id)

      Map.merge(rule, %{
        classes: classes,
        classes_csv: Enum.join(classes, ", ")
      })
    end)
  end

  def known_classes do
    from_users =
      try do
        Users.list_users(%{}, 1).classes
      rescue
        _ -> []
      end

    from_rules =
      @rules
      |> Enum.flat_map(& &1.default)

    (from_users ++ from_rules ++ ["anonymous", "user", "admin", "tag-dono", "taggers", "moderator"])
    |> Enum.map(&normalize_class/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp parse_classes(raw, defaults) do
    parsed =
      raw
      |> to_string()
      |> String.split([",", "\n", "\r", "\t", " "], trim: true)
      |> Enum.map(&normalize_class/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if parsed == [] do
      defaults
      |> Enum.map(&normalize_class/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    else
      parsed
    end
  end

  defp normalize_class(%{class: class}), do: normalize_class(class)

  defp normalize_class(class) do
    class
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace("_", "-")
  end
end
