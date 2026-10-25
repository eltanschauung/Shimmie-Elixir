defmodule ShimmiePhoenix.Site.TagRules do
  @moduledoc "Shared tag normalization helpers for aliases and auto-tag expansion.\n"

  alias ShimmiePhoenix.Repo
  alias ShimmiePhoenix.Site

  @max_alias_depth 32

  def normalize_and_expand(raw_tags) do
    raw_tags
    |> normalize_tags()
    |> apply_aliases_and_auto_tags()
  end

  def normalize_and_expand(common_tags, specific_tags) do
    [common_tags, specific_tags]
    |> Enum.map(&to_string(&1 || ""))
    |> Enum.join(" ")
    |> normalize_and_expand()
  end

  def resolve_search_terms(terms) when is_list(terms) do
    aliases =
      if terms == [] do
        %{}
      else
        alias_map()
      end

    Enum.map(terms, &resolve_search_term(&1, aliases))
  end

  def resolve_search_term(term) do
    resolve_search_term(term, alias_map())
  end

  defp resolve_search_term(term, aliases) when is_binary(term) do
    value = String.trim(term)

    {negative, body} =
      if String.starts_with?(value, "-") do
        {"-", String.trim_leading(value, "-")}
      else
        {"", value}
      end

    cond do
      body == "" ->
        value

      String.contains?(body, "*") ->
        value

      not Regex.match?(~r/^[a-zA-Z0-9_-]+$/, body) ->
        value

      true ->
        negative <> resolve_alias(String.downcase(body), aliases)
    end
  end

  defp resolve_search_term(term, _aliases) do
    to_string(term || "")
  end

  def autocomplete(search, limit \\ 100)

  def autocomplete(search, limit) when is_binary(search) and is_integer(limit) do
    trimmed = String.trim(search)

    if trimmed == "" do
      %{}
    else
      tag_counts = tag_counts_by_prefix(String.downcase(trimmed), limit)
      aliases = alias_suggestions(String.downcase(trimmed), limit)

      (tag_counts ++ aliases)
      |> Enum.sort_by(fn {tag, count} -> {-count, String.downcase(tag)} end)
      |> Enum.uniq_by(fn {tag, _count} -> String.downcase(tag) end)
      |> Enum.take(limit)
      |> Enum.reduce(%{}, fn {tag, count}, acc -> Map.put(acc, tag, count) end)
    end
  end

  def autocomplete(_, _) do
    %{}
  end

  defp apply_aliases_and_auto_tags(tags) do
    aliases = alias_map()
    auto_tags = auto_tag_map()

    tags
    |> Enum.map(&resolve_alias(&1, aliases))
    |> uniq_preserving_order()
    |> expand_auto_tags(aliases, auto_tags)
  end

  defp expand_auto_tags(tags, aliases, auto_tags) do
    set = MapSet.new(tags)
    expand_auto_tags(tags, set, tags, aliases, auto_tags)
  end

  defp expand_auto_tags([], _seen, acc, _aliases, _auto_tags) do
    acc
  end

  defp expand_auto_tags([tag | rest], seen, acc, aliases, auto_tags) do
    additions =
      auto_tags
      |> Map.get(tag, [])
      |> Enum.map(&resolve_alias(&1, aliases))
      |> Enum.reject(&MapSet.member?(seen, &1))
      |> uniq_preserving_order()

    next_seen = Enum.reduce(additions, seen, &MapSet.put(&2, &1))
    next_acc = acc ++ additions

    expand_auto_tags(rest ++ additions, next_seen, next_acc, aliases, auto_tags)
  end

  defp resolve_alias(tag, aliases) do
    do_resolve_alias(tag, aliases, MapSet.new(), 0)
  end

  defp do_resolve_alias(tag, _aliases, _seen, depth) when depth >= @max_alias_depth do
    tag
  end

  defp do_resolve_alias(tag, aliases, seen, depth) do
    lower = String.downcase(to_string(tag || ""))

    cond do
      lower == "" ->
        ""

      MapSet.member?(seen, lower) ->
        lower

      true ->
        case Map.get(aliases, lower) do
          nil -> lower
          next -> do_resolve_alias(next, aliases, MapSet.put(seen, lower), depth + 1)
        end
    end
  end

  defp normalize_tags(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.split(~r/[,\s]+/, trim: true)
    |> Enum.reject(&(&1 == ""))
    |> uniq_preserving_order()
  end

  defp uniq_preserving_order(values) do
    {rev, _seen} =
      Enum.reduce(values, {[], MapSet.new()}, fn value, {acc, seen} ->
        normalized = to_string(value || "")

        if normalized == "" or MapSet.member?(seen, normalized) do
          {acc, seen}
        else
          {[normalized | acc], MapSet.put(seen, normalized)}
        end
      end)

    Enum.reverse(rev)
  end

  defp alias_map do
    rows =
      if repo_table_exists?("aliases") do
        case Repo.query("SELECT oldtag, newtag FROM aliases", []) do
          {:ok, %{rows: result_rows}} -> result_rows
          _ -> []
        end
      else
        []
      end

    Enum.reduce(rows, %{}, fn
      [oldtag, newtag], acc ->
        old = oldtag |> to_string() |> String.downcase() |> String.trim()
        new = newtag |> to_string() |> String.downcase() |> String.trim()

        if old == "" or new == "" do
          acc
        else
          Map.put(acc, old, new)
        end

      _other, acc ->
        acc
    end)
  end

  defp auto_tag_map do
    rows =
      if repo_table_exists?("auto_tag") do
        case Repo.query("SELECT tag, additional_tags FROM auto_tag", []) do
          {:ok, %{rows: result_rows}} -> result_rows
          _ -> []
        end
      else
        []
      end

    Enum.reduce(rows, %{}, fn
      [tag, additional], acc ->
        key = tag |> to_string() |> String.downcase() |> String.trim()
        adds = normalize_tags(additional)

        if key == "" or adds == [] do
          acc
        else
          Map.update(acc, key, adds, fn existing ->
            uniq_preserving_order(existing ++ adds)
          end)
        end

      _other, acc ->
        acc
    end)
  end

  defp tag_counts_by_prefix(search, limit) do
    sql_like = escape_like(search) <> "%"

    rows =
      case Repo.query(
             "SELECT tag, count FROM tags WHERE LOWER(tag) LIKE $1 AND count > 0 " <>
               "ORDER BY count DESC, tag ASC LIMIT $2",
             [sql_like, limit]
           ) do
        {:ok, %{rows: result_rows}} -> result_rows
        _ -> []
      end

    Enum.map(rows, fn [tag, count] ->
      {to_string(tag || ""), parse_int(count)}
    end)
    |> Enum.reject(fn {tag, _count} -> tag == "" end)
  end

  defp alias_suggestions(search, limit) do
    sql_like = escape_like(search) <> "%"

    rows =
      if repo_table_exists?("aliases") do
        case Repo.query(
               "SELECT a.oldtag, COALESCE(t.count, 0) " <>
                 "FROM aliases a " <>
                 "LEFT JOIN tags t ON LOWER(t.tag) = LOWER(a.newtag) " <>
                 "WHERE LOWER(a.oldtag) LIKE $1 ESCAPE '\\' " <>
                 "ORDER BY COALESCE(t.count, 0) DESC, a.oldtag ASC LIMIT $2",
               [sql_like, limit]
             ) do
          {:ok, %{rows: result_rows}} -> result_rows
          _ -> []
        end
      else
        []
      end

    Enum.map(rows, fn [oldtag, count] ->
      {to_string(oldtag || ""), parse_int(count)}
    end)
    |> Enum.reject(fn {tag, _count} -> tag == "" end)
  end

  defp parse_int(value) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp repo_table_exists?(table_name) do
    case Repo.query(
           "SELECT 1 FROM information_schema.tables WHERE table_schema = CURRENT_SCHEMA() AND table_name = $1 LIMIT 1",
           [table_name]
         ) do
      {:ok, %{rows: [[1]]}} -> true
      {:ok, %{rows: rows}} -> rows != []
      _ -> false
    end
  end

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
