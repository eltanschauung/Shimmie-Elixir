defmodule ShimmiePhoenix.Site.Index do
  @moduledoc "Legacy-compatible post list and simple search helpers.\n"

  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Site.Permissions
  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.Site.TagRules
  alias ShimmiePhoenix.Repo

  def posts_per_page do
    case Store.get_config("index_images", "24") |> to_string() |> Integer.parse() do
      {n, ""} when n > 0 -> n
      _ -> 24
    end
  end

  def popular_tags(limit, omit_patterns \\ []) when is_integer(limit) and limit > 0 do
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
  end

  def list_posts(search, page, page_size, opts \\ []) do
    if valid_search?(search, page, page_size) do
      do_list_posts(search, page, min(page_size, 200), opts)
    else
      {[], 0}
    end
  end

  defp valid_search?(search, page, size) do
    (is_nil(search) or
       (is_binary(search) and byte_size(search) <= 4096 and String.valid?(search) and
          length(String.split(search, ~r/\s+/, trim: true)) <= 50)) and
      is_integer(page) and page in 1..10000 and is_integer(size) and size > 0
  end

  defp do_list_posts(search, page, page_size, opts) do
    current_user = normalize_user(opts)
    terms = parse_terms(search)
    offset = max(page - 1, 0) * page_size

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
  end

  def search_to_path(nil) do
    ""
  end

  def search_to_path("") do
    ""
  end

  def search_to_path(search) do
    URI.encode(search)
  end

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

  defp attach_tags_repo([]) do
    []
  end

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

  defp blank_to_nil(nil) do
    nil
  end

  defp blank_to_nil("") do
    nil
  end

  defp blank_to_nil(v) do
    v
  end

  defp parse_terms(nil) do
    []
  end

  defp parse_terms("") do
    []
  end

  defp parse_terms(search) do
    search
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> TagRules.resolve_search_terms()
  end

  defp repo_conditions(terms, current_user) do
    Enum.reduce(terms, {"", []}, fn term, {sql, params} ->
      {frag, vals} = repo_condition_for_term(term, length(params) + 1, current_user)

      if frag == "" do
        {sql, params}
      else
        joiner =
          if sql == "" do
            " WHERE "
          else
            " AND "
          end

        {sql <> joiner <> frag, params ++ vals}
      end
    end)
  end

  defp repo_omit_clause([], _start_idx) do
    {"", []}
  end

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
      joiner =
        if where_sql == "" do
          " WHERE "
        else
          " AND "
        end

      {where_sql <> joiner <> "COALESCE(images.approved, TRUE) = TRUE", params}
    else
      {where_sql, params}
    end
  end

  defp repo_condition_for_term("approved=" <> value, idx, current_user) do
    repo_approval_condition(value, idx, current_user)
  end

  defp repo_condition_for_term("approved:" <> value, idx, current_user) do
    repo_approval_condition(value, idx, current_user)
  end

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

  defp repo_condition_for_term("favorited_by=" <> username, idx, _current_user) do
    favorited_by_repo(username, idx)
  end

  defp repo_condition_for_term("favorited_by:" <> username, idx, _current_user) do
    favorited_by_repo(username, idx)
  end

  defp repo_condition_for_term("order:" <> _ord, _idx, _current_user) do
    {"", []}
  end

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

  defp normalize_user(opts) when is_list(opts) do
    opts
    |> Keyword.get(:current_user)
    |> normalize_user_map()
  end

  defp normalize_user(%{current_user: user}) do
    normalize_user_map(user)
  end

  defp normalize_user(_) do
    nil
  end

  defp normalize_user_map(%{id: id, class: class}) when is_integer(id) and is_binary(class) do
    %{id: id, class: String.downcase(class)}
  end

  defp normalize_user_map(_) do
    nil
  end

  defp can_approve?(%{class: class}) when is_binary(class) do
    Permissions.allowed?(:approve, class)
  end

  defp can_approve?(_) do
    false
  end

  defp logged_in?(%{id: id}) when is_integer(id) and id > 0 do
    true
  end

  defp logged_in?(_) do
    false
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
end
