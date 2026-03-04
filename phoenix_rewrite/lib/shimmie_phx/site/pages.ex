defmodule ShimmiePhoenix.Site.Pages do
  @moduledoc """
  Lightweight read helpers for legacy route pages.
  """

  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Site.Posts
  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.Site.TagRules
  alias ShimmiePhoenix.Repo

  @sqlite_separator <<31>>
  @sqlite_row_separator <<30>>

  def comment_list_count do
    case Store.get_config("comment_list_count", "10") |> to_string() |> Integer.parse() do
      {n, ""} when n >= 0 -> n
      _ -> 10
    end
  end

  def upload_count do
    case Store.get_config("upload_count", "3") |> to_string() |> Integer.parse() do
      {n, ""} when n > 0 -> n
      _ -> 3
    end
  end

  def upload_max_size do
    parse_size(
      Store.get_config("upload_size", Integer.to_string(10 * 1024 * 1024)),
      10 * 1024 * 1024
    )
  end

  def tags_min do
    case Store.get_config("tags_min", "3") |> to_string() |> Integer.parse() do
      {n, ""} when n > 0 -> n
      _ -> 3
    end
  end

  def list_comment_threads(page, per_page) do
    offset = max(page - 1, 0) * per_page
    ids = list_comment_thread_ids(per_page, offset)
    threads = ids |> Enum.map(&comment_thread/1) |> Enum.reject(&is_nil/1)
    {threads, count_comment_threads()}
  end

  def tags_map_data(starts_with \\ nil) do
    min_count = tags_min()
    pattern = tag_prefix_pattern(starts_with)

    rows =
      query_rows_typed(
        "SELECT tag, count FROM tags " <>
          "WHERE count >= :min_count AND LOWER(tag) LIKE :pattern ESCAPE '\\' " <>
          "ORDER BY LOWER(tag) LIMIT :limit",
        %{min_count: min_count, pattern: pattern, limit: 600}
      )

    Enum.map(rows, fn [tag, count] ->
      count_i = parse_int(count)

      %{
        tag: tag,
        count: count_i,
        scaled: tag_scale(count_i, min_count)
      }
    end)
  end

  def tags_alphabetic(starts_with \\ nil) do
    pattern = tag_prefix_pattern(starts_with)

    rows =
      query_rows_typed(
        "SELECT tag, count FROM tags " <>
          "WHERE count > 0 AND LOWER(tag) LIKE :pattern ESCAPE '\\' " <>
          "ORDER BY LOWER(tag) LIMIT :limit",
        %{pattern: pattern, limit: 3000}
      )

    rows
    |> Enum.map(fn [tag, count] -> %{tag: tag, count: parse_int(count)} end)
    |> Enum.group_by(fn row -> String.slice(String.downcase(row.tag), 0, 1) || "#" end)
    |> Enum.sort_by(fn {letter, _} -> letter end)
  end

  def tags_popularity do
    rows =
      query_rows_typed(
        "SELECT tag, count FROM tags WHERE count > 0 ORDER BY count DESC, tag ASC LIMIT :limit",
        %{limit: 3000}
      )

    rows
    |> Enum.map(fn [tag, count] ->
      count_i = parse_int(count)

      %{
        tag: tag,
        count: count_i,
        bucket: if(count_i > 0, do: :math.log10(count_i) |> Float.floor() |> trunc(), else: 0)
      }
    end)
    |> Enum.group_by(& &1.bucket)
    |> Enum.sort_by(fn {bucket, _} -> -bucket end)
  end

  def tag_az_letters do
    min_count = tags_min()

    rows =
      query_rows_typed(
        "SELECT DISTINCT LOWER(SUBSTR(tag, 1, 1)) AS letter " <>
          "FROM tags WHERE count >= :min_count ORDER BY letter",
        %{min_count: min_count}
      )

    Enum.map(rows, fn [letter] -> letter end)
  end

  def list_comments(page, per_page) do
    offset = max(page - 1, 0) * per_page

    case sqlite_db_path() do
      nil ->
        rows =
          query_rows(
            "SELECT c.id, c.image_id, COALESCE(u.name, 'Anonymous') AS owner_name, c.posted, c.comment " <>
              "FROM comments c LEFT JOIN users u ON u.id = c.owner_id " <>
              "ORDER BY c.id DESC LIMIT $1 OFFSET $2",
            [per_page, offset]
          )

        count =
          case Repo.query("SELECT COUNT(*) FROM comments") do
            {:ok, %{rows: [[value]]}} -> value
            _ -> 0
          end

        {rows, count}

      path ->
        sql =
          "SELECT c.id, c.image_id, COALESCE(u.name, 'Anonymous'), c.posted, c.comment " <>
            "FROM comments c LEFT JOIN users u ON u.id = c.owner_id " <>
            "ORDER BY c.id DESC LIMIT #{per_page} OFFSET #{offset}"

        rows = sqlite_rows(path, sql)

        count =
          case sqlite_single(path, "SELECT COUNT(*) FROM comments") do
            {:ok, value} -> parse_int(value)
            _ -> 0
          end

        {rows, count}
    end
  end

  def list_tags(sub, limit \\ 500) do
    {order_by, where_clause} =
      case sub do
        "popularity" -> {"count DESC, tag ASC", "WHERE count > 0"}
        _ -> {"tag ASC", "WHERE count > 0"}
      end

    case sqlite_db_path() do
      nil ->
        query_rows(
          "SELECT tag, count FROM tags #{where_clause} ORDER BY #{order_by} LIMIT $1",
          [limit]
        )

      path ->
        sql = "SELECT tag, count FROM tags #{where_clause} ORDER BY #{order_by} LIMIT #{limit}"
        sqlite_rows(path, sql)
    end
  end

  def list_blotter(limit \\ 100) do
    case sqlite_db_path() do
      nil ->
        query_rows(
          "SELECT id, entry_date, entry_text, important FROM blotter ORDER BY id DESC LIMIT $1",
          [limit]
        )

      path ->
        sql =
          "SELECT id, entry_date, entry_text, important FROM blotter ORDER BY id DESC LIMIT #{limit}"

        sqlite_rows(path, sql)
    end
  end

  def add_blotter_entry(entry_text, important \\ false)
  def add_blotter_entry(entry_text, important) when is_binary(entry_text) and is_boolean(important) do
    entry_text = String.trim(entry_text)

    cond do
      entry_text == "" ->
        {:error, :invalid_entry}

      true ->
        add_blotter_entry_db(entry_text, important)
    end
  end

  def add_blotter_entry(_, _), do: {:error, :invalid_entry}

  def wiki_latest(title) when is_binary(title) do
    escaped = escape_sqlite_string(title)

    case sqlite_db_path() do
      nil ->
        case Repo.query(
               "SELECT title, revision, date, body " <>
                 "FROM wiki_pages WHERE LOWER(title) = LOWER($1) ORDER BY revision DESC LIMIT 1",
               [title]
             ) do
          {:ok, %{rows: [[t, rev, date, body]]}} ->
            {:ok, %{title: t, revision: rev, date: to_string(date), body: body}}

          _ ->
            :not_found
        end

      path ->
        sql =
          "SELECT title, revision, date, body FROM wiki_pages " <>
            "WHERE LOWER(title) = LOWER('#{escaped}') ORDER BY revision DESC LIMIT 1"

        case sqlite_single_row(path, sql, 4) do
          {:ok, [t, rev, date, body]} ->
            {:ok, %{title: t, revision: parse_int(rev), date: date, body: body}}

          _ ->
            :not_found
        end
    end
  end

  def wiki_history(title, limit \\ 50) when is_binary(title) do
    escaped = escape_sqlite_string(title)

    case sqlite_db_path() do
      nil ->
        query_rows(
          "SELECT revision, date FROM wiki_pages WHERE LOWER(title) = LOWER($1) ORDER BY revision DESC LIMIT $2",
          [title, limit]
        )

      path ->
        sql =
          "SELECT revision, date FROM wiki_pages " <>
            "WHERE LOWER(title) = LOWER('#{escaped}') ORDER BY revision DESC LIMIT #{limit}"

        sqlite_rows(path, sql)
    end
  end

  def wiki_revision(title, revision)
      when is_binary(title) and is_integer(revision) and revision > 0 do
    escaped = escape_sqlite_string(title)

    case sqlite_db_path() do
      nil ->
        case Repo.query(
               "SELECT title, revision, date, body FROM wiki_pages " <>
                 "WHERE LOWER(title) = LOWER($1) AND revision = $2 LIMIT 1",
               [title, revision]
             ) do
          {:ok, %{rows: [[t, rev, date, body]]}} ->
            {:ok, %{title: t, revision: parse_int(rev), date: to_string(date), body: body}}

          _ ->
            {:error, :revision_not_found}
        end

      path ->
        sql =
          "SELECT title, revision, date, body FROM wiki_pages " <>
            "WHERE LOWER(title) = LOWER('#{escaped}') AND revision = #{revision} LIMIT 1"

        case sqlite_single_row(path, sql, 4) do
          {:ok, [t, rev, date, body]} ->
            {:ok, %{title: t, revision: parse_int(rev), date: date, body: body}}

          _ ->
            {:error, :revision_not_found}
        end
    end
  end

  def wiki_revision(_title, _revision), do: {:error, :revision_not_found}

  def wiki_save(title, body, owner_id, owner_ip)
      when is_binary(title) and is_integer(owner_id) and is_binary(owner_ip) do
    clean_title = String.trim(title)
    clean_body = to_string(body || "")

    cond do
      clean_title == "" ->
        {:error, :invalid_title}

      String.trim(clean_body) == "" ->
        {:error, :empty_body}

      true ->
        case sqlite_db_path() do
          nil -> wiki_save_repo(clean_title, clean_body, owner_id, owner_ip)
          path -> wiki_save_sqlite(path, clean_title, clean_body, owner_id, owner_ip)
        end
    end
  end

  def wiki_save(_title, _body, _owner_id, _owner_ip), do: {:error, :invalid_title}

  def wiki_delete(title) when is_binary(title) do
    clean_title = String.trim(title)

    if clean_title == "" do
      {:error, :invalid_title}
    else
      case sqlite_db_path() do
        nil ->
          case Repo.query("DELETE FROM wiki_pages WHERE LOWER(title) = LOWER($1)", [clean_title]) do
            {:ok, _} -> :ok
            _ -> {:error, :delete_failed}
          end

        path ->
          sql =
            "DELETE FROM wiki_pages WHERE LOWER(title) = LOWER(#{sqlite_literal(clean_title)})"

          sqlite_exec(path, sql)
      end
    end
  end

  def wiki_delete(_), do: {:error, :invalid_title}

  def wiki_revert(title, revision, owner_id, owner_ip)
      when is_binary(title) and is_integer(revision) and revision > 0 do
    with {:ok, page} <- wiki_revision(title, revision) do
      wiki_save(title, page.body, owner_id, owner_ip)
    end
  end

  def wiki_revert(_title, _revision, _owner_id, _owner_ip), do: {:error, :revision_not_found}

  def list_aliases(limit \\ 500) when is_integer(limit) and limit > 0 do
    case sqlite_db_path() do
      nil ->
        if repo_table_exists?("aliases") do
          query_rows(
            "SELECT oldtag, newtag FROM aliases ORDER BY LOWER(oldtag) ASC LIMIT $1",
            [limit]
          )
          |> Enum.map(fn [oldtag, newtag] -> %{oldtag: oldtag, newtag: newtag} end)
        else
          []
        end

      path ->
        if sqlite_table_exists?(path, "aliases") do
          sql = "SELECT oldtag, newtag FROM aliases ORDER BY LOWER(oldtag) ASC LIMIT #{limit}"

          sqlite_rows(path, sql)
          |> Enum.map(fn [oldtag, newtag] -> %{oldtag: oldtag, newtag: newtag} end)
        else
          []
        end
    end
  end

  def add_alias(oldtag, newtag) when is_binary(oldtag) and is_binary(newtag) do
    oldtag = String.trim(oldtag)
    newtag = String.trim(newtag)

    cond do
      oldtag == "" -> {:error, :invalid_oldtag}
      newtag == "" -> {:error, :invalid_newtag}
      String.downcase(oldtag) == String.downcase(newtag) -> {:error, :same_tag}
      true -> add_alias_db(oldtag, newtag)
    end
  end

  def add_alias(_, _), do: {:error, :invalid_oldtag}

  def remove_alias(oldtag) when is_binary(oldtag) do
    oldtag = String.trim(oldtag)

    if oldtag == "" do
      {:error, :invalid_oldtag}
    else
      case sqlite_db_path() do
        nil ->
          case Repo.query("DELETE FROM aliases WHERE oldtag = $1", [oldtag]) do
            {:ok, _} -> :ok
            _ -> {:error, :delete_failed}
          end

        path ->
          sqlite_exec(path, "DELETE FROM aliases WHERE oldtag = #{sqlite_literal(oldtag)}")
      end
    end
  end

  def remove_alias(_), do: {:error, :invalid_oldtag}

  def list_auto_tags(limit \\ 500) when is_integer(limit) and limit > 0 do
    case sqlite_db_path() do
      nil ->
        if repo_table_exists?("auto_tag") do
          query_rows(
            "SELECT tag, additional_tags FROM auto_tag ORDER BY LOWER(tag) ASC LIMIT $1",
            [limit]
          )
          |> Enum.map(fn [tag, additional_tags] ->
            %{tag: tag, additional_tags: additional_tags}
          end)
        else
          []
        end

      path ->
        if sqlite_table_exists?(path, "auto_tag") do
          sql = "SELECT tag, additional_tags FROM auto_tag ORDER BY LOWER(tag) ASC LIMIT #{limit}"

          sqlite_rows(path, sql)
          |> Enum.map(fn [tag, additional_tags] ->
            %{tag: tag, additional_tags: additional_tags}
          end)
        else
          []
        end
    end
  end

  def add_auto_tag(tag, additional_tags) when is_binary(tag) and is_binary(additional_tags) do
    tag = String.trim(tag)
    additional_tags = String.trim(additional_tags)

    cond do
      tag == "" -> {:error, :invalid_tag}
      additional_tags == "" -> {:error, :invalid_additional_tags}
      true -> add_auto_tag_db(tag, additional_tags)
    end
  end

  def add_auto_tag(_, _), do: {:error, :invalid_tag}

  def remove_auto_tag(tag) when is_binary(tag) do
    tag = String.trim(tag)

    if tag == "" do
      {:error, :invalid_tag}
    else
      case sqlite_db_path() do
        nil ->
          case Repo.query("DELETE FROM auto_tag WHERE tag = $1", [tag]) do
            {:ok, _} -> :ok
            _ -> {:error, :delete_failed}
          end

        path ->
          sqlite_exec(path, "DELETE FROM auto_tag WHERE tag = #{sqlite_literal(tag)}")
      end
    end
  end

  def remove_auto_tag(_), do: {:error, :invalid_tag}

  def autocomplete(search, limit \\ 100) when is_binary(search) do
    TagRules.autocomplete(search, limit)
  end

  def browser_search_suggestions(search, limit \\ 30) do
    sql_like = escape_like(String.downcase(search)) <> "%"

    rows =
      case sqlite_db_path() do
        nil ->
          query_rows(
            "SELECT tag FROM tags WHERE LOWER(tag) LIKE $1 AND count > 0 ORDER BY count DESC, tag ASC LIMIT $2",
            [sql_like, limit]
          )

        path ->
          sql =
            "SELECT tag FROM tags " <>
              "WHERE LOWER(tag) LIKE '#{escape_sqlite_string(sql_like)}' ESCAPE '\\' AND count > 0 " <>
              "ORDER BY count DESC, tag ASC LIMIT #{limit}"

          sqlite_rows(path, sql)
      end

    Enum.map(rows, fn [tag] -> tag end)
  end

  def random_post(search) do
    {_first_page, total_count} = ShimmiePhoenix.Site.Index.list_posts(search, 1, 1)

    case total_count do
      n when is_integer(n) and n > 0 ->
        page = :rand.uniform(n)

        case ShimmiePhoenix.Site.Index.list_posts(search, page, 1) do
          {[post], _} -> post
          {posts, _} -> List.first(posts)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def random_posts(search, count) when is_integer(count) and count > 0 do
    {_first_page, total_count} = ShimmiePhoenix.Site.Index.list_posts(search, 1, 1)

    case total_count do
      n when is_integer(n) and n > 0 ->
        sample_size = min(count, n)

        1..n
        |> Enum.take_random(sample_size)
        |> Enum.map(fn page ->
          case ShimmiePhoenix.Site.Index.list_posts(search, page, 1) do
            {[post], _} -> post
            {posts, _} -> List.first(posts)
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  def random_posts(_search, _count), do: []

  def site_title do
    Store.get_config("title", "Shimmie")
  end

  def extension_manager_rows(opts \\ []) do
    include_disabled = Keyword.get(opts, :include_disabled, true)
    enabled = MapSet.new(enabled_extensions())
    ext_root = legacy_ext_root()

    discovered =
      if is_binary(ext_root) and File.dir?(ext_root) do
        ext_root
        |> File.ls!()
        |> Enum.filter(&File.dir?(Path.join(ext_root, &1)))
      else
        []
      end

    native = Map.keys(native_extension_catalog())

    all_keys =
      discovered
      |> MapSet.new()
      |> MapSet.union(enabled)
      |> MapSet.union(MapSet.new(native))
      |> MapSet.to_list()

    rows =
      Enum.map(all_keys, fn key ->
        cond do
          Map.has_key?(native_extension_catalog(), key) ->
            native_extension_row(key, enabled)

          key in discovered and is_binary(ext_root) ->
            extension_row(key, enabled, ext_root)

          true ->
            fallback_extension_row(key, enabled)
        end
      end)

    rows
    |> maybe_filter_enabled(include_disabled)
    |> Enum.sort_by(fn row -> String.downcase(row.name) end)
  end

  def enabled_extension_keys do
    enabled_extensions()
  end

  def system_doc(topic) do
    docs = %{
      "comment" => %{
        title: "Comments Help",
        body_html:
          "<p>Browse recent comments from <code>/comment/list</code>.</p>" <>
            "<p>Search syntax for comment-related queries is available on <a href='/help/search'>Help / Searching</a>.</p>"
      },
      "tag_edit" => %{
        title: "Tag Help",
        body_html:
          "<p>Tag browsing is available via <a href='/tags/map'>Map</a>, <a href='/tags/alphabetic'>Alphabetic</a>, and <a href='/tags/popularity'>Popularity</a>.</p>" <>
            "<p>Search syntax is documented on <a href='/help/search'>Help / Searching</a>.</p>"
      },
      "wiki" => %{
        title: "Wiki Help",
        body_html:
          "<p>Wiki pages are available under <code>/wiki/&lt;title&gt;</code>.</p>" <>
            "<p>Use <a href='/wiki/wiki:list'>Page list</a> to browse known pages.</p>"
      }
    }

    Map.get(docs, topic)
  end

  def list_config_entries(limit \\ 250) do
    query = "SELECT name, COALESCE(value, '') FROM config ORDER BY LOWER(name) LIMIT :limit"

    query_rows_typed(query, %{limit: limit})
    |> Enum.map(fn [name, value] -> %{name: name, value: value} end)
  end

  def available_themes do
    themes_root = Path.join(Site.legacy_root(), "themes")

    if File.dir?(themes_root) do
      themes_root
      |> File.ls!()
      |> Enum.filter(&valid_theme_dir?(themes_root, &1))
      |> Enum.sort_by(&String.downcase/1)
      |> Enum.map(fn name ->
        %{value: name, label: humanize_theme_name(name)}
      end)
    else
      []
    end
  end

  def system_info_data do
    %{
      db_mode: if(is_nil(sqlite_db_path()), do: "repo", else: "sqlite"),
      post_count: Store.count_posts(),
      comment_count: table_count("comments"),
      user_count: table_count("users"),
      enabled_extensions: enabled_extensions() |> Enum.sort(),
      site_title: site_title()
    }
  end

  def source_history_for_image(image_id, limit \\ 100)

  def source_history_for_image(image_id, limit) when is_integer(image_id) and image_id > 0 do
    query_rows_typed(
      "SELECT sh.id, sh.image_id, COALESCE(sh.source, ''), COALESCE(u.name, 'Anonymous'), " <>
        "sh.user_ip, sh.date_set " <>
        "FROM source_histories sh LEFT JOIN users u ON u.id = sh.user_id " <>
        "WHERE sh.image_id = :image_id ORDER BY sh.id DESC LIMIT :limit",
      %{image_id: image_id, limit: limit}
    )
    |> Enum.map(fn [id, image_id, source, user_name, user_ip, date_set] ->
      %{
        id: parse_int(id),
        image_id: parse_int(image_id),
        value: source,
        user_name: user_name,
        user_ip: user_ip,
        date_set: date_set
      }
    end)
  end

  def source_history_for_image(_image_id, _limit), do: []

  def source_history_global(page, per_page \\ 100)

  def source_history_global(page, per_page) when is_integer(page) and page > 0 do
    offset = max(page - 1, 0) * per_page

    rows =
      query_rows_typed(
        "SELECT sh.id, sh.image_id, COALESCE(sh.source, ''), COALESCE(u.name, 'Anonymous'), " <>
          "sh.user_ip, sh.date_set " <>
          "FROM source_histories sh LEFT JOIN users u ON u.id = sh.user_id " <>
          "ORDER BY sh.id DESC LIMIT :limit OFFSET :offset",
        %{limit: per_page + 1, offset: offset}
      )

    {rows, has_next?} =
      if length(rows) > per_page do
        {Enum.take(rows, per_page), true}
      else
        {rows, false}
      end

    entries =
      Enum.map(rows, fn [id, image_id, source, user_name, user_ip, date_set] ->
        %{
          id: parse_int(id),
          image_id: parse_int(image_id),
          value: source,
          user_name: user_name,
          user_ip: user_ip,
          date_set: date_set
        }
      end)

    {entries, has_next?}
  end

  def source_history_global(_page, _per_page), do: {[], false}

  def tag_history_for_image(image_id, limit \\ 100)

  def tag_history_for_image(image_id, limit) when is_integer(image_id) and image_id > 0 do
    query_rows_typed(
      "SELECT th.id, th.image_id, COALESCE(th.tags, ''), COALESCE(u.name, 'Anonymous'), " <>
        "th.user_ip, th.date_set " <>
        "FROM tag_histories th LEFT JOIN users u ON u.id = th.user_id " <>
        "WHERE th.image_id = :image_id ORDER BY th.id DESC LIMIT :limit",
      %{image_id: image_id, limit: limit}
    )
    |> Enum.map(fn [id, image_id, tags, user_name, user_ip, date_set] ->
      %{
        id: parse_int(id),
        image_id: parse_int(image_id),
        value: tags,
        user_name: user_name,
        user_ip: user_ip,
        date_set: date_set
      }
    end)
  end

  def tag_history_for_image(_image_id, _limit), do: []

  def tag_history_global(page, per_page \\ 100)

  def tag_history_global(page, per_page) when is_integer(page) and page > 0 do
    offset = max(page - 1, 0) * per_page

    rows =
      query_rows_typed(
        "SELECT th.id, th.image_id, COALESCE(th.tags, ''), COALESCE(u.name, 'Anonymous'), " <>
          "th.user_ip, th.date_set " <>
          "FROM tag_histories th LEFT JOIN users u ON u.id = th.user_id " <>
          "ORDER BY th.id DESC LIMIT :limit OFFSET :offset",
        %{limit: per_page + 1, offset: offset}
      )

    {rows, has_next?} =
      if length(rows) > per_page do
        {Enum.take(rows, per_page), true}
      else
        {rows, false}
      end

    entries =
      Enum.map(rows, fn [id, image_id, tags, user_name, user_ip, date_set] ->
        %{
          id: parse_int(id),
          image_id: parse_int(image_id),
          value: tags,
          user_name: user_name,
          user_ip: user_ip,
          date_set: date_set
        }
      end)

    {entries, has_next?}
  end

  def tag_history_global(_page, _per_page), do: {[], false}

  def list_ip_bans(limit \\ 100) do
    query_rows_typed(
      "SELECT b.id, b.ip, b.mode, b.reason, b.added, COALESCE(b.expires, ''), " <>
        "COALESCE(u.name, 'Anonymous') " <>
        "FROM bans b LEFT JOIN users u ON u.id = b.banner_id " <>
        "ORDER BY b.id DESC LIMIT :limit",
      %{limit: limit}
    )
    |> Enum.map(fn [id, ip, mode, reason, added, expires, banner] ->
      %{
        id: parse_int(id),
        ip: ip,
        mode: mode,
        reason: reason,
        added: added,
        expires: expires,
        banner: banner
      }
    end)
  end

  defp list_comment_thread_ids(limit, offset) do
    rows =
      query_rows_typed(
        "SELECT image_id FROM comments GROUP BY image_id " <>
          "ORDER BY MAX(posted) DESC LIMIT :limit OFFSET :offset",
        %{limit: limit, offset: offset}
      )

    Enum.map(rows, fn [image_id] -> parse_int(image_id) end)
  end

  defp count_comment_threads do
    case query_rows_typed(
           "SELECT COUNT(*) FROM (SELECT image_id FROM comments GROUP BY image_id) AS t",
           %{}
         ) do
      [[count]] -> parse_int(count)
      _ -> 0
    end
  end

  defp comment_thread(image_id) when image_id > 0 do
    case Posts.get_post(image_id) do
      nil ->
        nil

      post ->
        owner_name = image_owner_name(image_id)
        comments = comments_for_image(image_id, comment_list_count())
        {thumb_w, thumb_h} = thumb_size(post.width, post.height)

        %{
          post: %{
            id: post.id,
            posted: post.posted,
            owner_name: owner_name,
            tags: post.tags || [],
            width: post.width,
            height: post.height,
            filesize: post.filesize,
            mime: MIME.from_path("x.#{post.ext}") || "application/octet-stream",
            thumb_url: Posts.thumb_route(post),
            thumb_width: thumb_w,
            thumb_height: thumb_h,
            thumb_tooltip: tooltip(post),
            rating_label: "Unrated"
          },
          comments: comments
        }
    end
  end

  defp comment_thread(_), do: nil

  defp comments_for_image(image_id, max_comments) do
    rows =
      query_rows_typed(
        "SELECT c.id, COALESCE(u.name, 'Anonymous'), c.posted, c.comment, COALESCE(c.owner_ip, '') " <>
          "FROM comments c LEFT JOIN users u ON u.id = c.owner_id " <>
          "WHERE c.image_id = :image_id ORDER BY c.id ASC",
        %{image_id: image_id}
      )

    clipped =
      if max_comments > 0 and length(rows) > max_comments do
        Enum.take(rows, -max_comments)
      else
        rows
      end

    Enum.flat_map(clipped, fn row ->
      case row do
        [id, owner_name, posted, comment, owner_ip] ->
          [
            %{
              id: parse_int(id),
              owner_name: owner_name,
              posted: posted,
              comment: comment,
              owner_ip: owner_ip
            }
          ]

        [comment] when is_binary(comment) ->
          [%{id: 0, owner_name: "Anonymous", posted: "", comment: comment, owner_ip: ""}]

        _ ->
          []
      end
    end)
  end

  defp image_owner_name(image_id) do
    case query_rows_typed(
           "SELECT COALESCE(u.name, 'Anonymous') FROM images i " <>
             "LEFT JOIN users u ON u.id = i.owner_id WHERE i.id = :image_id LIMIT 1",
           %{image_id: image_id}
         ) do
      [[name]] -> name
      _ -> "Anonymous"
    end
  end

  defp thumb_size(width, height) do
    thumb_width = config_int("thumb_width", 192)
    thumb_height = config_int("thumb_height", 192)

    w = if width > 0, do: width, else: 192
    h = if height > 0, do: height, else: 192

    w = if w > h * 5, do: h * 5, else: w
    h = if h > w * 5, do: w * 5, else: h
    scale = min(thumb_width / w, thumb_height / h)

    {max(1, trunc(w * scale)), max(1, trunc(h * scale))}
  end

  defp config_int(name, default) do
    case Store.get_config(name, Integer.to_string(default)) |> to_string() |> Integer.parse() do
      {value, ""} when value > 0 -> value
      _ -> default
    end
  end

  defp tooltip(post) do
    tags =
      case post.tags do
        [] -> "(no tags)"
        values -> Enum.join(values, " ")
      end

    "#{tags} // #{post.width}x#{post.height} // #{human_filesize(post.filesize)}"
  end

  defp human_filesize(value) when is_integer(value) and value >= 1024 * 1024 * 1024 do
    "#{Float.round(value / (1024 * 1024 * 1024), 1)}GB"
  end

  defp human_filesize(value) when is_integer(value) and value >= 1024 * 1024 do
    "#{Float.round(value / (1024 * 1024), 1)}MB"
  end

  defp human_filesize(value) when is_integer(value) and value >= 1024 do
    "#{Float.round(value / 1024, 1)}KB"
  end

  defp human_filesize(value) when is_integer(value), do: "#{value}B"
  defp human_filesize(_), do: "0B"

  defp tag_prefix_pattern(nil), do: "%"
  defp tag_prefix_pattern(""), do: "%"
  defp tag_prefix_pattern(value), do: escape_like(String.downcase(value)) <> "%"

  defp tag_scale(count, min_count) do
    base = max(count - min_count + 1, 1)
    scaled = :math.log(:math.log(base) + 1.0) * 1.5
    sized = Float.floor(max(scaled, 0.5) * 100.0) / 100.0
    Float.round(sized, 2)
  end

  defp valid_theme_dir?(themes_root, name) do
    path = Path.join(themes_root, name)
    File.dir?(path) and File.regular?(Path.join(path, "page.class.php"))
  end

  defp humanize_theme_name(name) do
    name
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp query_rows_typed(sql, params) when is_binary(sql) and is_map(params) do
    case sqlite_db_path() do
      nil -> query_rows_with_named_params_repo(sql, params)
      path -> query_rows_with_named_params_sqlite(path, sql, params)
    end
  end

  defp query_rows_with_named_params_repo(sql, params) do
    {compiled_sql, args} = named_to_positional(sql, params)
    query_rows(compiled_sql, args)
  end

  defp query_rows_with_named_params_sqlite(path, sql, params) do
    compiled_sql =
      Enum.reduce(params, sql, fn {key, value}, acc ->
        String.replace(acc, ":#{key}", sqlite_literal(value))
      end)

    sqlite_rows(path, compiled_sql)
  end

  defp named_to_positional(sql, params) do
    regex = ~r/:[a-zA-Z_][a-zA-Z0-9_]*/
    names = Regex.scan(regex, sql) |> Enum.map(fn [match] -> String.trim_leading(match, ":") end)
    params_by_name = Map.new(params, fn {key, value} -> {to_string(key), value} end)

    {compiled_sql, _index, args} =
      Enum.reduce(names, {sql, 1, []}, fn name, {current_sql, idx, current_args} ->
        value = Map.fetch!(params_by_name, name)
        replaced = String.replace(current_sql, ":#{name}", "$#{idx}", global: false)
        {replaced, idx + 1, current_args ++ [value]}
      end)

    {compiled_sql, args}
  end

  defp sqlite_literal(value) when is_integer(value), do: Integer.to_string(value)
  defp sqlite_literal(value) when is_float(value), do: Float.to_string(value)
  defp sqlite_literal(value) when is_boolean(value), do: if(value, do: "1", else: "0")
  defp sqlite_literal(value), do: "'#{escape_sqlite_string(to_string(value))}'"

  defp query_rows(sql, params) do
    case Repo.query(sql, params) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn row -> Enum.map(row, &to_string_if_needed/1) end)

      _ ->
        []
    end
  end

  defp to_string_if_needed(nil), do: ""
  defp to_string_if_needed(value) when is_binary(value), do: value
  defp to_string_if_needed(value), do: to_string(value)

  defp sqlite_rows(path, sql) do
    args = [
      "-noheader",
      "-separator",
      @sqlite_separator,
      "-newline",
      @sqlite_row_separator,
      path,
      sql
    ]

    case System.cmd("sqlite3", args, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split(@sqlite_row_separator, trim: true)
        |> Enum.map(fn line -> String.split(line, @sqlite_separator) end)

      _ ->
        []
    end
  end

  defp sqlite_single(path, sql) do
    case sqlite_rows(path, sql) do
      [[value] | _] -> {:ok, value}
      _ -> {:error, :not_found}
    end
  end

  defp sqlite_single_row(path, sql, _parts) do
    case sqlite_rows(path, sql) do
      [line | _] -> {:ok, line}
      _ -> {:error, :sqlite_failed}
    end
  end

  defp wiki_save_repo(title, body, owner_id, owner_ip) do
    with {:ok, %{rows: [[next_id]]}} <-
           Repo.query("SELECT COALESCE(MAX(id), 0) + 1 FROM wiki_pages"),
         {:ok, %{rows: [[next_revision]]}} <-
           Repo.query(
             "SELECT COALESCE(MAX(revision), 0) + 1 FROM wiki_pages WHERE LOWER(title) = LOWER($1)",
             [title]
           ),
         {:ok, _} <-
           Repo.query(
             "INSERT INTO wiki_pages(id, owner_id, owner_ip, date, title, revision, locked, body) " <>
               "VALUES ($1, $2, $3, NOW(), $4, $5, FALSE, $6)",
             [parse_int(next_id), owner_id, owner_ip, title, parse_int(next_revision), body]
           ) do
      :ok
    else
      _ -> {:error, :save_failed}
    end
  end

  defp wiki_save_sqlite(path, title, body, owner_id, owner_ip) do
    with :ok <- ensure_sqlite_wiki_table(path),
         {:ok, next_id} <- sqlite_single(path, "SELECT COALESCE(MAX(id), 0) + 1 FROM wiki_pages"),
         {:ok, next_revision} <-
           sqlite_single(
             path,
             "SELECT COALESCE(MAX(revision), 0) + 1 FROM wiki_pages WHERE LOWER(title) = LOWER(#{sqlite_literal(title)})"
           ),
         :ok <-
           sqlite_exec(
             path,
             "INSERT INTO wiki_pages(id, owner_id, owner_ip, date, title, revision, locked, body) VALUES (" <>
               "#{parse_int(next_id)}, #{owner_id}, #{sqlite_literal(owner_ip)}, #{sqlite_literal(timestamp_now())}, " <>
               "#{sqlite_literal(title)}, #{parse_int(next_revision)}, 0, #{sqlite_literal(body)})"
           ) do
      :ok
    else
      _ -> {:error, :save_failed}
    end
  end

  defp add_alias_db(oldtag, newtag) do
    case sqlite_db_path() do
      nil ->
        with :ok <- ensure_repo_aliases_table(),
             {:ok, _} <-
               Repo.query(
                 "INSERT INTO aliases(oldtag, newtag) VALUES ($1, $2) " <>
                   "ON CONFLICT(oldtag) DO UPDATE SET newtag = EXCLUDED.newtag",
                 [oldtag, newtag]
               ) do
          :ok
        else
          _ -> {:error, :save_failed}
        end

      path ->
        with :ok <- ensure_sqlite_aliases_table(path),
             :ok <-
               sqlite_exec(path, "DELETE FROM aliases WHERE oldtag = #{sqlite_literal(oldtag)}"),
             :ok <-
               sqlite_exec(
                 path,
                 "INSERT INTO aliases(oldtag, newtag) VALUES (#{sqlite_literal(oldtag)}, #{sqlite_literal(newtag)})"
               ) do
          :ok
        else
          _ -> {:error, :save_failed}
        end
    end
  end

  defp add_auto_tag_db(tag, additional_tags) do
    case sqlite_db_path() do
      nil ->
        with :ok <- ensure_repo_auto_tag_table(),
             {:ok, _} <-
               Repo.query(
                 "INSERT INTO auto_tag(tag, additional_tags) VALUES ($1, $2) " <>
                   "ON CONFLICT(tag) DO UPDATE SET additional_tags = EXCLUDED.additional_tags",
                 [tag, additional_tags]
               ) do
          :ok
        else
          _ -> {:error, :save_failed}
        end

      path ->
        with :ok <- ensure_sqlite_auto_tag_table(path),
             :ok <- sqlite_exec(path, "DELETE FROM auto_tag WHERE tag = #{sqlite_literal(tag)}"),
             :ok <-
               sqlite_exec(
                 path,
                 "INSERT INTO auto_tag(tag, additional_tags) VALUES (#{sqlite_literal(tag)}, #{sqlite_literal(additional_tags)})"
               ) do
          :ok
        else
          _ -> {:error, :save_failed}
        end
    end
  end

  defp add_blotter_entry_db(entry_text, important) do
    case sqlite_db_path() do
      nil ->
        with :ok <- ensure_repo_blotter_table(),
             {:ok, %{rows: [[next_id]]}} <-
               Repo.query("SELECT COALESCE(MAX(id), 0) + 1 FROM blotter"),
             {:ok, _} <-
               Repo.query(
                 "INSERT INTO blotter(id, entry_date, entry_text, important) VALUES ($1, NOW(), $2, $3)",
                 [parse_int(next_id), entry_text, important]
               ) do
          :ok
        else
          _ -> {:error, :save_failed}
        end

      path ->
        with :ok <- ensure_sqlite_blotter_table(path),
             {:ok, next_id} <- sqlite_single(path, "SELECT COALESCE(MAX(id), 0) + 1 FROM blotter"),
             :ok <-
               sqlite_exec(
                 path,
                 "INSERT INTO blotter(id, entry_date, entry_text, important) VALUES (" <>
                   "#{parse_int(next_id)}, #{sqlite_literal(timestamp_now())}, " <>
                   "#{sqlite_literal(entry_text)}, #{if(important, do: 1, else: 0)})"
               ) do
          :ok
        else
          _ -> {:error, :save_failed}
        end
    end
  end

  defp ensure_repo_aliases_table do
    case Repo.query(
           "CREATE TABLE IF NOT EXISTS aliases (oldtag TEXT PRIMARY KEY, newtag TEXT NOT NULL)"
         ) do
      {:ok, _} -> :ok
      _ -> {:error, :create_failed}
    end
  end

  defp ensure_repo_auto_tag_table do
    case Repo.query(
           "CREATE TABLE IF NOT EXISTS auto_tag (tag TEXT PRIMARY KEY, additional_tags TEXT NOT NULL)"
         ) do
      {:ok, _} -> :ok
      _ -> {:error, :create_failed}
    end
  end

  defp ensure_repo_blotter_table do
    case Repo.query(
           "CREATE TABLE IF NOT EXISTS blotter (" <>
             "id BIGINT PRIMARY KEY, " <>
             "entry_date TIMESTAMP NOT NULL DEFAULT NOW(), " <>
             "entry_text TEXT NOT NULL, " <>
             "important BOOLEAN NOT NULL DEFAULT FALSE)"
         ) do
      {:ok, _} -> :ok
      _ -> {:error, :create_failed}
    end
  end

  defp ensure_sqlite_aliases_table(path) do
    sqlite_exec(
      path,
      "CREATE TABLE IF NOT EXISTS aliases (oldtag TEXT PRIMARY KEY, newtag TEXT NOT NULL)"
    )
  end

  defp ensure_sqlite_auto_tag_table(path) do
    sqlite_exec(
      path,
      "CREATE TABLE IF NOT EXISTS auto_tag (tag TEXT PRIMARY KEY, additional_tags TEXT NOT NULL)"
    )
  end

  defp ensure_sqlite_blotter_table(path) do
    sqlite_exec(
      path,
      "CREATE TABLE IF NOT EXISTS blotter (" <>
        "id INTEGER PRIMARY KEY, " <>
        "entry_date TEXT NOT NULL, " <>
        "entry_text TEXT NOT NULL, " <>
        "important INTEGER NOT NULL DEFAULT 0)"
    )
  end

  defp ensure_sqlite_wiki_table(path) do
    sqlite_exec(
      path,
      "CREATE TABLE IF NOT EXISTS wiki_pages (" <>
        "id INTEGER PRIMARY KEY, owner_id INTEGER NOT NULL DEFAULT 1, owner_ip TEXT NOT NULL DEFAULT '', " <>
        "date TEXT NOT NULL, title TEXT NOT NULL, revision INTEGER NOT NULL, locked INTEGER NOT NULL DEFAULT 0, body TEXT NOT NULL)"
    )
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

  defp sqlite_table_exists?(path, table_name) do
    case sqlite_single(
           path,
           "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = #{sqlite_literal(table_name)} LIMIT 1"
         ) do
      {:ok, "1"} -> true
      _ -> false
    end
  end

  defp sqlite_exec(path, sql) do
    case System.cmd("sqlite3", [path, sql], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      _ -> {:error, :sqlite_failed}
    end
  end

  defp timestamp_now do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_string()
  end

  defp sqlite_db_path do
    case Site.sqlite_db_path() do
      nil -> nil
      path -> if File.exists?(path), do: path, else: nil
    end
  end

  defp parse_int(value) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp parse_size(value, default) do
    raw = value |> to_string() |> String.trim()

    case Regex.run(~r/^([0-9]+(?:\.[0-9]+)?)\s*([kmgt]?b?)?$/i, raw) do
      [_, number, unit] ->
        multiplier =
          case String.downcase(unit || "") do
            "" -> 1
            "b" -> 1
            "k" -> 1024
            "kb" -> 1024
            "m" -> 1024 * 1024
            "mb" -> 1024 * 1024
            "g" -> 1024 * 1024 * 1024
            "gb" -> 1024 * 1024 * 1024
            "t" -> 1024 * 1024 * 1024 * 1024
            "tb" -> 1024 * 1024 * 1024 * 1024
            _ -> 1
          end

        case Float.parse(number) do
          {n, ""} ->
            parsed = trunc(n * multiplier)
            if(parsed > 0, do: parsed, else: default)

          _ ->
            default
        end

      _ ->
        default
    end
  end

  defp escape_sqlite_string(value), do: String.replace(value, "'", "''")

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp maybe_filter_enabled(rows, true), do: rows
  defp maybe_filter_enabled(rows, false), do: Enum.filter(rows, & &1.enabled?)

  defp table_count(table) do
    case query_rows_typed("SELECT COUNT(*) FROM #{table}", %{}) do
      [[count]] -> parse_int(count)
      _ -> 0
    end
  end

  defp enabled_extensions do
    from_legacy =
      case legacy_extensions_config_path() do
        nil ->
          []

        path ->
          case File.read(path) do
            {:ok, body} ->
              parse_enabled_extensions_from_legacy(body)

            _ ->
              []
          end
      end

    if from_legacy != [] do
      from_legacy
    else
      read_enabled_extensions_fallback()
    end
  end

  defp extension_row(key, enabled, ext_root) do
    info_path = Path.join([ext_root, key, "info.php"])
    {name, description} = parse_extension_info(info_path, key)

    %{
      key: key,
      name: name,
      description: description,
      enabled?: MapSet.member?(enabled, key)
    }
  end

  defp fallback_extension_row(key, enabled) do
    %{
      key: key,
      name: humanize_extension_key(key),
      description: "",
      enabled?: MapSet.member?(enabled, key)
    }
  end

  defp native_extension_row(key, enabled) do
    details = Map.get(native_extension_catalog(), key, %{name: humanize_extension_key(key), description: ""})

    %{
      key: key,
      name: details.name,
      description: details.description,
      enabled?: MapSet.member?(enabled, key) or key == "telegram_alerts"
    }
  end

  defp native_extension_catalog do
    %{
      "telegram_alerts" => %{
        name: "Telegram Alerts",
        description: "Send notifications to Telegram for uploads, approvals, and comments."
      }
    }
  end

  defp parse_extension_info(path, key) do
    case File.read(path) do
      {:ok, body} ->
        name =
          regex_capture(
            body,
            ~r/public string \$name\s*=\s*"([^"]+)"/,
            humanize_extension_key(key)
          )

        description = regex_capture(body, ~r/public string \$description\s*=\s*"([^"]*)"/, "")

        {name, description}

      _ ->
        {humanize_extension_key(key), ""}
    end
  end

  defp regex_capture(body, regex, fallback) do
    case Regex.run(regex, body) do
      [_, value] -> value
      _ -> fallback
    end
  end

  defp humanize_extension_key(key) do
    key
    |> String.split("_")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp legacy_ext_root do
    case Site.legacy_root() do
      root when is_binary(root) -> Path.join(root, "ext")
      _ -> nil
    end
  end

  defp legacy_extensions_config_path do
    case Site.legacy_root() do
      root when is_binary(root) -> Path.join([root, "data", "config", "extensions.conf.php"])
      _ -> nil
    end
  end

  defp parse_enabled_extensions_from_legacy(body) when is_binary(body) do
    php_array_values =
      Regex.scan(~r/'([a-zA-Z0-9_]+)'/, body)
      |> Enum.map(fn [_, value] -> value end)
      |> Enum.reject(&(&1 in ["ExtManager", "Array"]))

    extra_ext_values =
      case Regex.run(
             ~r/EXTRA_EXTS["']?\s*,\s*["']([^"']+)["']/,
             body,
             capture: :all_but_first
           ) do
        [csv] ->
          csv
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        _ ->
          []
      end

    (php_array_values ++ extra_ext_values)
    |> Enum.uniq()
  end

  defp read_enabled_extensions_fallback do
    fallback_path = Path.expand("../../../../extensions_enabled.txt", __DIR__)

    case File.read(fallback_path) do
      {:ok, body} ->
        body
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

      _ ->
        []
    end
  end
end
