defmodule ShimmiePhoenix.Site.Comments do
  @moduledoc "Legacy-compatible comment write helpers for `/comment/add`.\n"

  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Site.Approval
  alias ShimmiePhoenix.Site.Permissions
  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.Site.TagEdit
  alias ShimmiePhoenix.Site.Users
  alias ShimmiePhoenix.Repo

  def can_delete_comment?(actor) do
    actor_id(actor) > 0 and Permissions.allowed?(:comment_delete, actor_class(actor))
  end

  def can_create_comment?(nil) do
    Permissions.allowed?(:comment_create, "anonymous")
  end

  def can_create_comment?(actor) do
    actor_id(actor) > 0 and Permissions.allowed?(:comment_create, actor_class(actor))
  end

  def can_view_ip?(actor) do
    actor_id(actor) > 0 and Permissions.allowed?(:comment_view_ip, actor_class(actor))
  end

  def can_ban_ip?(actor) do
    actor_id(actor) > 0 and Permissions.allowed?(:comment_ban_ip, actor_class(actor))
  end

  def anonymous_user?(actor) do
    anonymous_actor?(actor)
  end

  def bypass_comment_checks?(actor) do
    TagEdit.can_edit_tags?(actor)
  end

  def form_hash(remote_ip) when is_binary(remote_ip) do
    day = Date.utc_today() |> Calendar.strftime("%Y%m%d")
    :crypto.hash(:md5, remote_ip <> day) |> Base.encode16(case: :lower)
  end

  def form_hash(_) do
    form_hash("0.0.0.0")
  end

  def add(params, actor, remote_ip) when is_map(params) do
    backend = :repo

    with true <- can_create_comment?(actor),
         {:ok, image_id} <- parse_image_id(Map.get(params, "image_id")),
         {:ok, comment} <- normalize_comment(Map.get(params, "comment")),
         :ok <- ensure_image_visible(image_id, actor),
         :ok <- verify_anonymous_form_hash(actor, params["hash"], remote_ip),
         :ok <- verify_anonymous_comment_checks(actor, image_id, comment, remote_ip, backend),
         {:ok, _comment_id} <-
           insert_comment(image_id, actor_user_id(actor), remote_ip, comment, backend) do
      {:ok, image_id}
    else
      false -> {:error, :permission_denied}
      {:error, _} = error -> error
      _ -> {:error, :create_failed}
    end
  end

  def add(_, _, _) do
    {:error, :invalid_request}
  end

  def deletion_target(comment_id, actor) do
    with {:ok, parsed_id} <- parse_image_id(comment_id),
         true <- can_delete_comment?(actor),
         {:ok, image_id} <- comment_image_id(parsed_id, :repo) do
      {:ok, %{id: parsed_id, image_id: image_id}}
    else
      false -> {:error, :permission_denied}
      {:error, _} = error -> error
      _ -> {:error, :delete_failed}
    end
  end

  def delete(comment_id, actor) do
    with {:ok, target} <- deletion_target(comment_id, actor),
         :ok <- delete_comment_row(target.id, :repo) do
      {:ok, target.image_id}
    end
  end

  defp verify_anonymous_comment_checks(actor, image_id, comment, remote_ip, backend) do
    if bypass_comment_checks?(actor) do
      :ok
    else
      with :ok <- ensure_not_repetitive(comment),
           :ok <- ensure_not_rate_limited(remote_ip, backend),
           :ok <- ensure_not_duplicate(image_id, comment, backend) do
        :ok
      end
    end
  end

  defp ensure_not_repetitive(comment) do
    compressed_size =
      try do
        :zlib.compress(comment) |> byte_size()
      rescue
        _ -> 1
      end

    if byte_size(comment) > 0 and compressed_size > 0 and
         byte_size(comment) / compressed_size > 10 do
      {:error, :comment_too_repetitive}
    else
      :ok
    end
  end

  defp verify_anonymous_form_hash(actor, supplied_hash, remote_ip) do
    if bypass_comment_checks?(actor) do
      :ok
    else
      expected = form_hash(remote_ip)
      supplied = supplied_hash |> to_string() |> String.trim() |> String.downcase()

      if supplied != "" and supplied == expected do
        :ok
      else
        {:error, :form_out_of_date}
      end
    end
  end

  defp ensure_not_duplicate(image_id, comment, :repo) do
    duplicate? = repo_comment_exists?(image_id, comment)

    if duplicate? do
      {:error, :duplicate_comment}
    else
      :ok
    end
  end

  defp ensure_not_duplicate(_image_id, _comment, _backend) do
    duplicate? = false

    if duplicate? do
      {:error, :duplicate_comment}
    else
      :ok
    end
  end

  defp ensure_not_rate_limited(remote_ip, :repo) do
    max_comments = config_int("comment_limit", 10)
    window_minutes = config_int("comment_window", 5)

    cond do
      max_comments <= 0 or window_minutes <= 0 ->
        :ok

      not repo_has_column?("comments", "owner_ip") or not repo_has_column?("comments", "posted") ->
        :ok

      true ->
        case Repo.query(
               "SELECT COUNT(*) FROM comments WHERE owner_ip = $1 AND posted > NOW() - make_interval(mins => $2::int)",
               [remote_ip, window_minutes]
             ) do
          {:ok, %{rows: [[count]]}} ->
            if parse_int(count) >= max_comments do
              {:error, :rate_limited}
            else
              :ok
            end

          _ ->
            :ok
        end
    end
  end

  defp ensure_not_rate_limited(_remote_ip, _backend) do
    :ok
  end

  defp ensure_image_visible(image_id, actor) do
    if Approval.can_view_image?(image_id, actor) do
      :ok
    else
      {:error, :post_not_found}
    end
  end

  defp comment_image_id(comment_id, :repo) do
    case Repo.query("SELECT image_id FROM comments WHERE id = $1 LIMIT 1", [comment_id]) do
      {:ok, %{rows: [[image_id]]}} -> {:ok, parse_int(image_id)}
      _ -> {:error, :comment_not_found}
    end
  end

  defp comment_image_id(_comment_id, _backend) do
    {:error, :comment_not_found}
  end

  defp delete_comment_row(comment_id, :repo) do
    case Repo.query("DELETE FROM comments WHERE id = $1", [comment_id]) do
      {:ok, _} -> :ok
      _ -> {:error, :delete_failed}
    end
  end

  defp delete_comment_row(_comment_id, _backend) do
    {:error, :delete_failed}
  end

  defp insert_comment(image_id, owner_id, remote_ip, comment, backend) do
    comment_id = next_comment_id(backend)

    case backend do
      :repo ->
        insert_comment_repo(comment_id, image_id, owner_id, remote_ip, comment)

      _ ->
        {:error, :create_failed}
    end
  end

  defp next_comment_id(:repo) do
    ShimmiePhoenix.IDAllocator.next!("comments")
  end

  defp next_comment_id(_backend) do
    1
  end

  defp insert_comment_repo(comment_id, image_id, owner_id, remote_ip, comment) do
    {columns, values, args, next_index} =
      {["id", "image_id", "owner_id"], ["$1", "$2", "$3"], [comment_id, image_id, owner_id], 4}

    {columns, values, args, next_index} =
      if repo_has_column?("comments", "owner_ip") do
        {columns ++ ["owner_ip"], values ++ ["$#{next_index}"], args ++ [remote_ip],
         next_index + 1}
      else
        {columns, values, args, next_index}
      end

    {columns, values, args} =
      if repo_has_column?("comments", "posted") do
        {columns ++ ["posted"], values ++ ["NOW()"], args}
      else
        {columns, values, args}
      end

    columns = columns ++ ["comment"]
    values = values ++ ["$#{next_index}"]
    args = args ++ [comment]

    sql =
      "INSERT INTO comments(" <>
        Enum.join(columns, ", ") <>
        ") VALUES (" <>
        Enum.join(values, ", ") <> ")"

    case Repo.query(sql, args) do
      {:ok, _} -> {:ok, comment_id}
      _ -> {:error, :create_failed}
    end
  end

  defp repo_comment_exists?(image_id, comment) do
    case Repo.query(
           "SELECT 1 FROM comments WHERE image_id = $1 AND comment = $2 LIMIT 1",
           [image_id, comment]
         ) do
      {:ok, %{rows: [[1]]}} -> true
      {:ok, %{rows: rows}} -> rows != []
      _ -> false
    end
  end

  defp parse_image_id(value) do
    case Integer.parse(to_string(value || "")) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_image_id}
    end
  end

  defp normalize_comment(value) do
    comment = to_string(value || "")

    cond do
      String.trim(comment) == "" ->
        {:error, :empty_comment}

      byte_size(comment) > 9000 ->
        {:error, :comment_too_long}

      true ->
        {:ok, comment}
    end
  end

  defp actor_user_id(%{id: id}) do
    parsed = parse_int(id)

    if parsed > 0 do
      parsed
    else
      Users.anonymous_id()
    end
  end

  defp actor_user_id(_) do
    Users.anonymous_id()
  end

  defp anonymous_actor?(actor) do
    anon_id = Users.anonymous_id()

    case actor do
      nil ->
        true

      %{id: id, class: class} ->
        parsed = parse_int(id)
        parsed <= 0 or parsed == anon_id or actor_class(%{class: class}) == "anonymous"

      _ ->
        true
    end
  end

  defp config_int(name, default) do
    case Store.get_config(name, Integer.to_string(default)) |> to_string() |> Integer.parse() do
      {value, ""} when value > 0 -> value
      _ -> default
    end
  end

  defp parse_int(value) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp repo_has_column?(table, column) do
    case Repo.query(
           "SELECT 1 FROM information_schema.columns " <>
             "WHERE table_schema = CURRENT_SCHEMA() AND table_name = $1 AND column_name = $2 LIMIT 1",
           [table, column]
         ) do
      {:ok, %{rows: [[1]]}} -> true
      {:ok, %{rows: rows}} -> rows != []
      _ -> false
    end
  end

  defp normalize_class(class) do
    class
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp actor_id(%{id: id}) do
    parse_int(id)
  end

  defp actor_id(_) do
    0
  end

  defp actor_class(%{class: class}) do
    normalize_class(class)
  end

  defp actor_class(_) do
    ""
  end
end
