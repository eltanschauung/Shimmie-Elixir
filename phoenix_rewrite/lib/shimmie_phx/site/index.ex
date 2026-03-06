defmodule ShimmiePhoenix.Site.Index do
  @moduledoc """
  Legacy-compatible post list and simple search helpers.
  """

  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Site.Permissions
  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.Site.TagRules
  alias ShimmiePhoenix.Repo

  @sqlite_separator <<31>>
  @sqlite_tag_separator <<29>>
  def posts_per_page do
    case Store.get_config("index_images", "24") |> to_string() |> Integer.parse() do
      {n, ""} when n > 0 -> n
      _ -> 24
    end
  end

  def popular_tags(limit, omit_patterns \\ []) when is_integer(limit) and limit > 0 do
    case sqlite_db_path() do
      nil ->
        {omit_sql, params} = repo_omit_clause(omit_patterns, 1)

        query =
          "SELECT tag, count FROM tags WHERE count > 0" <>
            omit_sql <> " ORDER BY count DESC, tag ASC LIMIT $#{length(params) + 1}"

        case Repo.query(query, params ++ [limit]) do
          {:ok, %{rows: rows}} ->
            Enum.map(rows, fn [tag, count] ->
              %{tag: to_string(tag), count: parse_int(to_string(count))}
            end)

          _ ->
            []
        end

      path ->
        omit_sql = sqlite_omit_clause(omit_patterns)

        query =
          "SELECT tag, count FROM tags WHERE count > 0" <>
            omit_sql <> " ORDER BY count DESC, tag ASC LIMIT #{limit}"

        case sqlite_rows(path, query) do
          {:ok, rows} ->
            Enum.map(rows, fn line ->
              case String.split(line, @sqlite_separator, parts: 2) do
                [tag, count] -> %{tag: tag, count: parse_int(count)}
                _ -> %{tag: "", count: 0}
              end
            end)
            |> Enum.reject(&(&1.tag == ""))

          _ ->
            []
        end
    end
  end

  def list_posts(search, page, page_size, opts \\ []) do
    current_user = normalize_user(opts)
    terms = parse_terms(search)
    offset = max(page - 1, 0) * page_size

    case sqlite_db_path() do
      nil ->
        {where_sql, params} =
          terms
          |> repo_conditions(current_user)
          |> append_repo_visibility_filter(terms)

        order_sql = " ORDER BY images.id DESC "

        rows =
          Repo.query!(
            "SELECT images.id, images.hash, images.ext, images.filename, images.width, images.height, images.filesize, COALESCE(images.source, ''), images.posted, COALESCE(images.favorites, 0) " <>
              "FROM images " <>
              where_sql <>
              order_sql <> " LIMIT $#{length(params) + 1} OFFSET $#{length(params) + 2}",
            params ++ [page_size, offset]
          ).rows

        posts = rows |> Enum.map(&row_to_post/1) |> attach_tags_repo()
        {posts, count_repo(where_sql, params)}

      path ->
        {where_sql, ok?} =
          terms
          |> sqlite_conditions(current_user)
          |> append_sqlite_visibility_filter(path, terms)

        if ok? do
          order_sql = " ORDER BY images.id DESC "

          select_sql =
            "SELECT images.id, images.hash, images.ext, images.filename, images.width, images.height, images.filesize, COALESCE(images.source, ''), images.posted, COALESCE(images.favorites, 0), " <>
              "COALESCE((SELECT GROUP_CONCAT(t.tag, char(29)) FROM image_tags it JOIN tags t ON t.id = it.tag_id WHERE it.image_id = images.id), ''), " <>
              "COUNT(*) OVER() " <>
              "FROM images " <> where_sql <> order_sql <> " LIMIT #{page_size} OFFSET #{offset}"

          {posts, count} =
            case sqlite_rows(path, select_sql) do
              {:ok, rows} ->
                parsed =
                  rows
                  |> Enum.map(&sqlite_row_to_post_with_count/1)
                  |> Enum.reject(&is_nil/1)

                posts = Enum.map(parsed, & &1.post)

                count =
                  case parsed do
                    [%{total_count: total_count} | _] ->
                      total_count

                    [] when offset > 0 ->
                      case sqlite_single_line(path, "SELECT COUNT(*) FROM images " <> where_sql) do
                        {:ok, value} ->
                          case Integer.parse(value) do
                            {n, ""} -> n
                            _ -> 0
                          end

                        _ ->
                          0
                      end

                    [] ->
                      0
                  end

                {posts, count}

              _ ->
                {[], 0}
            end

          {posts, count}
        else
          {[], 0}
        end
    end
  end

  def search_to_path(nil), do: ""
  def search_to_path(""), do: ""
  def search_to_path(search), do: URI.encode(search)

  defp count_repo(where_sql, params) do
    case Repo.query("SELECT COUNT(*) FROM images " <> where_sql, params) do
      {:ok, %{rows: [[count]]}} -> count
      _ -> 0
    end
  end

  defp row_to_post([id, hash, ext, filename, width, height, filesize, source, posted, favorites]) do
    %{
      id: id,
      hash: hash,
      ext: ext,
      filename: filename,
      width: width,
      height: height,
      filesize: filesize,
      source: blank_to_nil(source),
      posted: to_string(posted),
      favorites: favorites,
      tags: []
    }
  end

  defp sqlite_row_to_post_with_count(line) do
    case String.split(line, @sqlite_separator, parts: 12) do
      [
        id,
        hash,
        ext,
        filename,
        width,
        height,
        filesize,
        source,
        posted,
        favorites,
        tags_blob,
        total_count
      ] ->
        post = %{
          id: String.to_integer(id),
          hash: hash,
          ext: ext,
          filename: filename,
          width: String.to_integer(width),
          height: String.to_integer(height),
          filesize: String.to_integer(filesize),
          source: blank_to_nil(source),
          posted: posted,
          favorites: parse_int(favorites),
          tags: parse_sqlite_tags_blob(tags_blob)
        }

        %{post: post, total_count: parse_int(total_count)}

      _ ->
        nil
    end
  end

  defp parse_sqlite_tags_blob(""), do: []

  defp parse_sqlite_tags_blob(blob) when is_binary(blob) do
    blob
    |> String.split(@sqlite_tag_separator, trim: true)
    |> Enum.sort()
  end

  defp attach_tags_repo([]), do: []

  defp attach_tags_repo(posts) do
    ids = Enum.map(posts, & &1.id)
    {placeholder_sql, params} = placeholder_params(ids)

    tag_map =
      case Repo.query(
             "SELECT it.image_id, t.tag " <>
               "FROM image_tags it JOIN tags t ON t.id = it.tag_id " <>
               "WHERE it.image_id IN (" <>
               placeholder_sql <>
               ") " <>
               "ORDER BY it.image_id, t.tag",
             params
           ) do
        {:ok, %{rows: rows}} ->
          Enum.reduce(rows, %{}, fn [image_id, tag], acc ->
            Map.update(acc, image_id, [tag], fn tags -> [tag | tags] end)
          end)
          |> Map.new(fn {image_id, tags} -> {image_id, Enum.reverse(tags)} end)

        _ ->
          %{}
      end

    Enum.map(posts, fn post -> Map.put(post, :tags, Map.get(tag_map, post.id, [])) end)
  end

  defp placeholder_params(values) do
    sql =
      values
      |> Enum.with_index(1)
      |> Enum.map(fn {_value, index} -> "$#{index}" end)
      |> Enum.join(",")

    {sql, values}
  end

  defp parse_int(value) do
    case Integer.parse(value || "") do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp parse_terms(nil), do: []
  defp parse_terms(""), do: []

  defp parse_terms(search) do
    search
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&TagRules.resolve_search_term/1)
  end

  defp repo_conditions(terms, current_user) do
    Enum.reduce(terms, {"", []}, fn term, {sql, params} ->
      {frag, vals} = repo_condition_for_term(term, length(params) + 1, current_user)

      if frag == "" do
        {sql, params}
      else
        joiner = if sql == "", do: " WHERE ", else: " AND "
        {sql <> joiner <> frag, params ++ vals}
      end
    end)
  end

  defp repo_omit_clause([], _start_idx), do: {"", []}

  defp repo_omit_clause(patterns, start_idx) do
    {frags, params, _next_idx} =
      Enum.reduce(patterns, {[], [], start_idx}, fn pattern, {acc_frags, acc_params, idx} ->
        if String.contains?(pattern, "*") do
          like = String.replace(pattern, "*", "%")
          {["tag ILIKE $#{idx}" | acc_frags], acc_params ++ [like], idx + 1}
        else
          {["tag = $#{idx}" | acc_frags], acc_params ++ [pattern], idx + 1}
        end
      end)

    clause = " AND NOT (" <> Enum.join(Enum.reverse(frags), " OR ") <> ")"
    {clause, params}
  end

  defp append_repo_visibility_filter({where_sql, params}, terms) do
    if repo_has_column?("images", "approved") and not has_approval_query?(terms) do
      joiner = if where_sql == "", do: " WHERE ", else: " AND "
      {where_sql <> joiner <> "COALESCE(images.approved, TRUE) = TRUE", params}
    else
      {where_sql, params}
    end
  end

  defp repo_condition_for_term("approved=" <> value, idx, current_user),
    do: repo_approval_condition(value, idx, current_user)

  defp repo_condition_for_term("approved:" <> value, idx, current_user),
    do: repo_approval_condition(value, idx, current_user)

  defp repo_condition_for_term("-" <> tag, idx, _current_user) when tag != "" do
    if String.contains?(tag, "*") do
      like = String.replace(tag, "*", "%")

      {"images.id NOT IN (SELECT it.image_id FROM image_tags it JOIN tags t ON t.id = it.tag_id WHERE t.tag ILIKE $#{idx})",
       [like]}
    else
      {"images.id NOT IN (SELECT it.image_id FROM image_tags it JOIN tags t ON t.id = it.tag_id WHERE t.tag = $#{idx})",
       [tag]}
    end
  end

  defp repo_condition_for_term("favorited_by=" <> username, idx, _current_user),
    do: favorited_by_repo(username, idx)

  defp repo_condition_for_term("favorited_by:" <> username, idx, _current_user),
    do: favorited_by_repo(username, idx)

  defp repo_condition_for_term("order:" <> _ord, _idx, _current_user), do: {"", []}

  defp repo_condition_for_term(tag, idx, _current_user) do
    if String.contains?(tag, "*") do
      like = String.replace(tag, "*", "%")

      {"images.id IN (SELECT it.image_id FROM image_tags it JOIN tags t ON t.id = it.tag_id WHERE t.tag ILIKE $#{idx})",
       [like]}
    else
      {"images.id IN (SELECT it.image_id FROM image_tags it JOIN tags t ON t.id = it.tag_id WHERE t.tag = $#{idx})",
       [tag]}
    end
  end

  defp favorited_by_repo(username, idx) do
    {"images.id IN (SELECT uf.image_id FROM user_favorites uf JOIN users u ON u.id = uf.user_id WHERE u.name = $#{idx})",
     [username]}
  end

  defp sqlite_conditions(terms, current_user) do
    Enum.reduce_while(terms, {"", true}, fn term, {sql, _ok} ->
      case sqlite_condition_for_term(term, current_user) do
        {:ok, frag} ->
          joiner = if sql == "", do: " WHERE ", else: " AND "
          {:cont, {sql <> joiner <> frag, true}}

        :skip ->
          {:cont, {sql, true}}

        {:error, _} ->
          {:halt, {"", false}}
      end
    end)
  end

  defp append_sqlite_visibility_filter({where_sql, ok?}, path, terms) do
    if ok? and sqlite_has_column?(path, "images", "approved") and not has_approval_query?(terms) do
      joiner = if where_sql == "", do: " WHERE ", else: " AND "
      {where_sql <> joiner <> "COALESCE(images.approved, 1) = 1", true}
    else
      {where_sql, ok?}
    end
  end

  defp sqlite_condition_for_term("approved=" <> value, current_user),
    do: sqlite_approval_condition(value, current_user)

  defp sqlite_condition_for_term("approved:" <> value, current_user),
    do: sqlite_approval_condition(value, current_user)

  defp sqlite_condition_for_term("-" <> tag, _current_user) when tag != "" do
    {:ok,
     "images.id NOT IN (SELECT it.image_id FROM image_tags it JOIN tags t ON t.id = it.tag_id WHERE t.tag #{sqlite_tag_match(tag)})"}
  end

  defp sqlite_condition_for_term("favorited_by=" <> username, _current_user),
    do: {:ok, sqlite_favorited_by(username)}

  defp sqlite_condition_for_term("favorited_by:" <> username, _current_user),
    do: {:ok, sqlite_favorited_by(username)}

  defp sqlite_condition_for_term("order:" <> _, _current_user), do: :skip

  defp sqlite_condition_for_term(tag, _current_user) do
    {:ok,
     "images.id IN (SELECT it.image_id FROM image_tags it JOIN tags t ON t.id = it.tag_id WHERE t.tag #{sqlite_tag_match(tag)})"}
  end

  defp has_approval_query?(terms) do
    Enum.any?(terms, fn term ->
      case String.downcase(term) do
        "approved=yes" -> true
        "approved=no" -> true
        "approved:yes" -> true
        "approved:no" -> true
        _ -> false
      end
    end)
  end

  defp repo_approval_condition(value, idx, current_user) do
    case String.downcase(String.trim(value)) do
      "yes" ->
        {"COALESCE(images.approved, TRUE) = TRUE", []}

      "no" ->
        cond do
          can_approve?(current_user) ->
            {"COALESCE(images.approved, TRUE) != TRUE", []}

          logged_in?(current_user) ->
            {"COALESCE(images.approved, TRUE) != TRUE AND COALESCE(images.owner_id, 0) = $#{idx}",
             [current_user.id]}

          true ->
            {"1 = 0", []}
        end

      _ ->
        {"1 = 0", []}
    end
  end

  defp sqlite_approval_condition(value, current_user) do
    case String.downcase(String.trim(value)) do
      "yes" ->
        {:ok, "COALESCE(images.approved, 1) = 1"}

      "no" ->
        cond do
          can_approve?(current_user) ->
            {:ok, "COALESCE(images.approved, 1) != 1"}

          logged_in?(current_user) ->
            {:ok,
             "COALESCE(images.approved, 1) != 1 AND COALESCE(images.owner_id, 0) = #{current_user.id}"}

          true ->
            {:ok, "1 = 0"}
        end

      _ ->
        {:ok, "1 = 0"}
    end
  end

  defp normalize_user(opts) when is_list(opts) do
    opts
    |> Keyword.get(:current_user)
    |> normalize_user_map()
  end

  defp normalize_user(%{current_user: user}), do: normalize_user_map(user)
  defp normalize_user(_), do: nil

  defp normalize_user_map(%{id: id, class: class}) when is_integer(id) and is_binary(class),
    do: %{id: id, class: String.downcase(class)}

  defp normalize_user_map(_), do: nil

  defp can_approve?(%{class: class}) when is_binary(class) do
    Permissions.allowed?(:approve, class)
  end

  defp can_approve?(_), do: false

  defp logged_in?(%{id: id}) when is_integer(id) and id > 0, do: true
  defp logged_in?(_), do: false

  defp sqlite_omit_clause([]), do: ""

  defp sqlite_omit_clause(patterns) do
    frags =
      patterns
      |> Enum.map(fn pattern ->
        if String.contains?(pattern, "*") do
          "tag LIKE '#{escape_sqlite_string(String.replace(pattern, "*", "%"))}' ESCAPE '\\'"
        else
          "tag = '#{escape_sqlite_string(pattern)}'"
        end
      end)
      |> Enum.reject(&(&1 == ""))

    if frags == [], do: "", else: " AND NOT (" <> Enum.join(frags, " OR ") <> ")"
  end

  defp sqlite_tag_match(tag) do
    if String.contains?(tag, "*") do
      like = String.replace(tag, "*", "%") |> escape_sqlite_string()
      "LIKE '#{like}' ESCAPE '\\'"
    else
      "= '#{escape_sqlite_string(tag)}'"
    end
  end

  defp sqlite_favorited_by(username) do
    u = escape_sqlite_string(username)

    "images.id IN (SELECT uf.image_id FROM user_favorites uf JOIN users u ON u.id = uf.user_id WHERE u.name = '#{u}')"
  end

  defp sqlite_db_path do
    case Site.sqlite_db_path() do
      nil -> nil
      path -> if File.exists?(path), do: path, else: nil
    end
  end

  defp repo_has_column?(table, column) do
    case Repo.query(
           "SELECT 1 FROM information_schema.columns WHERE table_name = $1 AND column_name = $2 LIMIT 1",
           [table, column]
         ) do
      {:ok, %{rows: [[1]]}} -> true
      {:ok, %{rows: rows}} -> rows != []
      _ -> false
    end
  end

  defp sqlite_has_column?(path, table, column) do
    escaped_table = escape_sqlite_string(table)

    case sqlite_rows(path, "PRAGMA table_info('#{escaped_table}')") do
      {:ok, rows} ->
        Enum.any?(rows, fn row ->
          case String.split(row, @sqlite_separator) do
            [_cid, name | _] -> String.downcase(name) == String.downcase(column)
            _ -> false
          end
        end)

      _ ->
        false
    end
  end

  defp sqlite_rows(path, query) do
    args = ["-noheader", "-separator", @sqlite_separator, path, query]

    case System.cmd("sqlite3", args, stderr_to_stdout: true) do
      {output, 0} ->
        rows = output |> String.split("\n", trim: true) |> Enum.reject(&(&1 == ""))
        {:ok, rows}

      _ ->
        {:error, :sqlite_failed}
    end
  end

  defp sqlite_single_line(path, query) do
    with {:ok, rows} <- sqlite_rows(path, query),
         [line | _] <- rows do
      {:ok, String.trim(line)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp escape_sqlite_string(value), do: String.replace(value, "'", "''")
end
