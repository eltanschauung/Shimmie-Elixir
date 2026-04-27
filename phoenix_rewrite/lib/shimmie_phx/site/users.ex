defmodule ShimmiePhoenix.Site.Users do
  @moduledoc """
  Legacy-compatible user/account helpers for /user_admin routes.
  """

  import Bitwise
  require Logger

  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.Repo

  @username_regex ~r/^[a-zA-Z0-9\-_]+$/
  @sqlite_separator <<31>>
  @sqlite_row_separator <<30>>
  @site_user_id_key :site_user_id
  @site_user_name_key :site_user_name
  @legacy_user_id_key :legacy_user_id
  @legacy_user_name_key :legacy_user_name
  @login_throttle_table :shimmie_login_throttle
  @login_throttle_owner :shimmie_login_throttle_owner
  @login_throttle_window_ms 15 * 60 * 1000
  @login_throttle_max_failures 10

  def signup_enabled?, do: config_bool("login_signup_enabled", true)
  def user_email_required?, do: config_bool("user_email_required", false)

  def login_redirect_mode,
    do: to_string(Store.get_config("user_login_redirect", "previous") || "previous")

  def login_memory_days, do: config_int("login_memory", 365)

  def session_hash_mask,
    do: to_string(Store.get_config("session_hash_mask", "255.255.0.0") || "255.255.0.0")

  def recaptcha_site_key, do: to_string(Store.get_config("api_recaptcha_pubkey", "") || "")
  def anonymous_id, do: config_int("anon_id", 1)

  def current_user(conn) do
    case session_user_id(conn) do
      id when is_integer(id) and id > 0 ->
        user_by_id(id)

      _ ->
        conn = Plug.Conn.fetch_cookies(conn)
        name = conn.cookies["shm_user"] || conn.cookies["user"]
        token = conn.cookies["shm_session"] || conn.cookies["session"]

        if is_binary(name) and name != "" and is_binary(token) and token != "" do
          case user_by_name(name) do
            nil ->
              nil

            user ->
              if valid_session?(user, token, remote_ip_string(conn.remote_ip)),
                do: user,
                else: nil
          end
        else
          nil
        end
    end
  end

  def session_user_id(conn) do
    case Plug.Conn.get_session(conn, @site_user_id_key) ||
           Plug.Conn.get_session(conn, @legacy_user_id_key) do
      id when is_integer(id) and id > 0 -> id
      _ -> nil
    end
  end

  def session_user_name(conn) do
    case Plug.Conn.get_session(conn, @site_user_name_key) ||
           Plug.Conn.get_session(conn, @legacy_user_name_key) do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  def put_user_session(conn, %{id: id, name: name}) when is_integer(id) and is_binary(name) do
    conn
    |> Plug.Conn.put_session(@site_user_id_key, id)
    |> Plug.Conn.put_session(@legacy_user_id_key, id)
    |> put_user_name_session(name)
  end

  def put_user_name_session(conn, name) when is_binary(name) do
    conn
    |> Plug.Conn.put_session(@site_user_name_key, name)
    |> Plug.Conn.put_session(@legacy_user_name_key, name)
  end

  def get_user_by_id(id) when is_integer(id) and id > 0, do: user_by_id(id)
  def get_user_by_id(_), do: nil

  def get_user_by_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    user_by_name(trimmed) ||
      user_by_name(String.replace(trimmed, " ", "_")) ||
      user_by_name(String.replace(trimmed, "_", " "))
  end

  def get_user_by_name(_), do: nil

  def login(name, pass, remote_ip) when is_binary(name) and is_binary(pass) do
    backend = active_backend()
    trimmed_name = String.trim(name)
    throttle_key = login_throttle_key(trimmed_name, remote_ip)

    Logger.info("auth.login attempt user=#{trimmed_name} backend=#{backend}")

    with :ok <- login_throttle_allowed?(throttle_key) do
      case user_by_name(trimmed_name) ||
             user_by_name(String.replace(trimmed_name, " ", "_")) do
        nil ->
          record_login_failure(throttle_key)

          Logger.warning(
            "auth.login failure user=#{trimmed_name} backend=#{backend} reason=user_not_found"
          )

          {:error, :invalid_credentials}

        user ->
          case password_status(user, pass) do
            {:ok, authed_user} ->
              clear_login_failures(throttle_key)

              Logger.info(
                "auth.login success user=#{authed_user.name} class=#{authed_user.class} backend=#{backend}"
              )

              {:ok, authed_user, session_id(authed_user.passhash, remote_ip)}

            :error ->
              record_login_failure(throttle_key)

              Logger.warning(
                "auth.login failure user=#{trimmed_name} backend=#{backend} reason=bad_password"
              )

              {:error, :invalid_credentials}
          end
      end
    end
  end

  def create_user(attrs, remote_ip, opts \\ %{}) when is_map(attrs) do
    columns = user_columns()
    name = attrs |> Map.get("name", "") |> to_string() |> String.trim()
    pass1 = attrs |> Map.get("pass1", "") |> to_string()
    pass2 = attrs |> Map.get("pass2", "") |> to_string()
    email = attrs |> Map.get("email", "") |> to_string() |> String.trim()
    login? = Map.get(opts, :login, true)

    with :ok <- validate_username(name),
         :ok <- ensure_username_available(name),
         :ok <- validate_passwords(pass1, pass2),
         :ok <- validate_email_requirement(email) do
      class_name =
        Map.get(opts, :class) ||
          if(MapSet.member?(columns, "class"), do: first_user_class(), else: nil)

      base_cols = []
      base_vals = []

      {cols, vals} =
        if MapSet.member?(columns, "id") do
          {[~s("id") | base_cols], [next_user_id() | base_vals]}
        else
          {base_cols, base_vals}
        end

      cols = cols ++ [~s("name")]
      vals = vals ++ [name]

      {cols, vals} =
        if MapSet.member?(columns, "pass") do
          {cols ++ [~s("pass")], vals ++ [Bcrypt.hash_pwd_salt(pass1)]}
        else
          {cols, vals}
        end

      {cols, vals} =
        if MapSet.member?(columns, "email") do
          value = if(email == "", do: nil, else: email)
          {cols ++ [~s("email")], vals ++ [value]}
        else
          {cols, vals}
        end

      {cols, vals} =
        if MapSet.member?(columns, "class") and is_binary(class_name) and class_name != "" do
          {cols ++ [~s("class")], vals ++ [class_name]}
        else
          {cols, vals}
        end

      {cols, vals} =
        if MapSet.member?(columns, "joindate") do
          {cols ++ [~s("joindate")],
           vals ++ [NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)]}
        else
          {cols, vals}
        end

      case insert_user(cols, vals) do
        {:ok, _} ->
          user = user_by_name(name)

          cond do
            is_nil(user) ->
              {:error, :create_failed}

            login? ->
              {:ok, user, session_id(user.passhash, remote_ip)}

            true ->
              {:ok, user, nil}
          end

        _ ->
          {:error, :create_failed}
      end
    end
  end

  def list_users(params, default_page_size \\ 100) when is_map(params) do
    columns = user_columns()
    page_size = parse_positive(params["r__size"], default_page_size) |> min(500)
    page = parse_positive(params["r__page"], 1)
    r_dates = normalize_joindate(params["r_joindate"])

    filter_state = %{
      r_id:
        params
        |> Map.get("r_id", "")
        |> to_string()
        |> then(fn v ->
          parsed = parse_positive(v, 0)
          if parsed > 0, do: Integer.to_string(parsed), else: ""
        end),
      r_name: params |> Map.get("r_name", "") |> to_string() |> String.trim(),
      r_email: params |> Map.get("r_email", "") |> to_string() |> String.trim(),
      r_class: params |> Map.get("r_class", "") |> to_string() |> String.trim(),
      r_joindate: [r_dates.from, r_dates.to]
    }

    if use_sqlite?() do
      list_users_sqlite(params, columns, page_size, page, filter_state)
    else
      list_users_repo(params, columns, page_size, page)
    end
  end

  defp list_users_repo(params, columns, page_size, page) do
    {where_sql, args, next_idx, filter_state} = build_user_where(params, columns)
    total_count = users_count(where_sql, args)
    total_pages = max(1, div(total_count + page_size - 1, page_size))
    page = min(max(page, 1), total_pages)
    offset = (page - 1) * page_size
    email_enabled? = MapSet.member?(columns, "email")

    join_date_expr =
      if MapSet.member?(columns, "joindate") do
        "COALESCE(CAST(joindate AS TEXT), '')"
      else
        "''"
      end

    class_expr =
      if MapSet.member?(columns, "class") do
        "COALESCE(class, 'user')"
      else
        "'user'"
      end

    email_expr =
      if email_enabled? do
        "COALESCE(email, '')"
      else
        "''"
      end

    sort = normalize_sort(params["r__sort"], columns)

    sql =
      "SELECT id, name, #{class_expr} AS class, #{join_date_expr} AS joindate, #{email_expr} AS email " <>
        "FROM users#{where_sql} ORDER BY #{sort_order(sort)} " <>
        "LIMIT $#{next_idx} OFFSET $#{next_idx + 1}"

    rows =
      case Repo.query(sql, args ++ [page_size, offset]) do
        {:ok, %{rows: values}} ->
          Enum.map(values, fn [id, name, class_name, join_date, email] ->
            %{
              id: parse_positive(id, 0),
              name: to_string(name || ""),
              class: to_string(class_name || "user"),
              join_date: join_date |> to_string() |> String.slice(0, 10),
              email: to_string(email || "")
            }
          end)

        _ ->
          []
      end

    %{
      users: rows,
      classes: list_classes(columns),
      page: page,
      page_size: page_size,
      total_pages: total_pages,
      total_count: total_count,
      sort: sort,
      filters: filter_state,
      email_enabled?: email_enabled?
    }
  end

  defp list_users_sqlite(params, columns, page_size, page, filter_state) do
    {where_sql, sort} = sqlite_user_filters(params, columns)
    total_count = sqlite_count("SELECT COUNT(*) FROM users#{where_sql}")
    total_pages = max(1, div(total_count + page_size - 1, page_size))
    page = min(max(page, 1), total_pages)
    offset = (page - 1) * page_size

    join_date_expr =
      if MapSet.member?(columns, "joindate"),
        do: "COALESCE(CAST(joindate AS TEXT), '')",
        else: "''"

    class_expr =
      if MapSet.member?(columns, "class"), do: "COALESCE(class, 'user')", else: "'user'"

    email_enabled? = MapSet.member?(columns, "email")
    email_expr = if(email_enabled?, do: "COALESCE(email, '')", else: "''")

    sql =
      "SELECT id, name, #{class_expr} AS class, #{join_date_expr} AS joindate, #{email_expr} AS email " <>
        "FROM users#{where_sql} ORDER BY #{sort_order(sort)} " <>
        "LIMIT #{page_size} OFFSET #{offset}"

    rows =
      sqlite_rows(sql)
      |> Enum.map(fn [id, name, class_name, join_date, email] ->
        %{
          id: parse_positive(id, 0),
          name: to_string(name || ""),
          class: to_string(class_name || "user"),
          join_date: join_date |> to_string() |> String.slice(0, 10),
          email: to_string(email || "")
        }
      end)

    %{
      users: rows,
      classes: list_classes(columns),
      page: page,
      page_size: page_size,
      total_pages: total_pages,
      total_count: total_count,
      sort: sort,
      filters: filter_state,
      email_enabled?: email_enabled?
    }
  end

  def recover(username) do
    case user_by_name(username) do
      nil ->
        {:error, :user_not_found}

      %{email: nil} ->
        {:error, :no_email}

      %{email: ""} ->
        {:error, :no_email}

      _ ->
        {:error, :not_implemented}
    end
  end

  def change_name(actor, params) do
    with {:ok, user_id} <- parse_user_id(params["id"]),
         user when not is_nil(user) <- user_by_id(user_id),
         :ok <- ensure_can_edit(actor, user),
         :ok <- validate_username(Map.get(params, "name", "") |> to_string() |> String.trim()),
         :ok <-
           ensure_username_available_for(
             Map.get(params, "name", "") |> to_string() |> String.trim(),
             user.id
           ),
         {:ok, _} <-
           update_user_name(user.id, Map.get(params, "name", "") |> to_string() |> String.trim()) do
      {:ok, user_by_id(user.id)}
    else
      {:error, _} = err -> err
      nil -> {:error, :user_not_found}
      _ -> {:error, :update_failed}
    end
  end

  def change_pass(actor, params, remote_ip) do
    with {:ok, user_id} <- parse_user_id(params["id"]),
         user when not is_nil(user) <- user_by_id(user_id),
         :ok <- ensure_can_edit(actor, user),
         :ok <- validate_passwords(Map.get(params, "pass1", ""), Map.get(params, "pass2", "")),
         true <- MapSet.member?(user_columns(), "pass"),
         {:ok, _} <-
           update_user_password(user.id, Bcrypt.hash_pwd_salt(Map.get(params, "pass1", ""))) do
      refreshed = user_by_id(user.id)
      {:ok, refreshed, session_id(refreshed.passhash, remote_ip)}
    else
      {:error, _} = err -> err
      nil -> {:error, :user_not_found}
      false -> {:error, :pass_column_missing}
      _ -> {:error, :update_failed}
    end
  end

  def change_email(actor, params) do
    columns = user_columns()

    with true <- MapSet.member?(columns, "email"),
         {:ok, user_id} <- parse_user_id(params["id"]),
         user when not is_nil(user) <- user_by_id(user_id),
         :ok <- ensure_can_edit(actor, user),
         :ok <- validate_email(Map.get(params, "address", "")),
         {:ok, _} <- update_user_email(user.id, Map.get(params, "address", "")) do
      {:ok, user_by_id(user.id)}
    else
      {:error, _} = err -> err
      nil -> {:error, :user_not_found}
      false -> {:error, :email_column_missing}
      _ -> {:error, :update_failed}
    end
  end

  def change_class(actor, params) do
    columns = user_columns()

    with true <- MapSet.member?(columns, "class"),
         :ok <- ensure_admin(actor),
         {:ok, user_id} <- parse_user_id(params["id"]),
         user when not is_nil(user) <- user_by_id(user_id),
         class_name when is_binary(class_name) <-
           Map.get(params, "class", "") |> to_string() |> String.trim(),
         true <- class_name != "",
         {:ok, _} <- update_user_class(user.id, class_name) do
      {:ok, user_by_id(user.id)}
    else
      {:error, _} = err -> err
      nil -> {:error, :user_not_found}
      false -> {:error, :invalid_class}
      _ -> {:error, :update_failed}
    end
  end

  def delete_user(actor, params) do
    with :ok <- ensure_admin(actor),
         {:ok, user_id} <- parse_user_id(params["id"]),
         user when not is_nil(user) <- user_by_id(user_id),
         false <- user.id == anonymous_id() do
      with_images = truthy?(Map.get(params, "with_images"))
      with_comments = truthy?(Map.get(params, "with_comments"))
      anon = anonymous_id()

      if with_images do
        _ = delete_user_images(user.id)
      else
        _ = reassign_user_images(user.id, anon)
      end

      if with_comments do
        _ = delete_user_comments(user.id)
      else
        _ = reassign_user_comments(user.id, anon)
      end

      _ = delete_user_favorites(user.id)

      case delete_user_row(user.id) do
        {:ok, _} -> {:ok, :deleted}
        _ -> {:error, :delete_failed}
      end
    else
      {:error, _} = err -> err
      nil -> {:error, :user_not_found}
      true -> {:error, :cannot_delete_anon}
      _ -> {:error, :delete_failed}
    end
  end

  def session_id(passhash, remote_ip) when is_binary(remote_ip) do
    hash = (passhash || "") <> masked_session_ip(remote_ip) <> Site.secret()
    :crypto.hash(:sha3_256, hash) |> Base.encode16(case: :lower)
  end

  def remote_ip_string(%Plug.Conn{} = conn) do
    proxy_tuple = normalize_ipv4_mapped_ipv6(conn.remote_ip)
    proxy_ip = remote_ip_string(proxy_tuple)

    if trusted_proxy?(proxy_tuple) do
      conn
      |> forwarded_for()
      |> forwarded_for_ip()
      |> case do
        nil -> proxy_ip
        ip -> ip
      end
    else
      proxy_ip
    end
  end

  def remote_ip_string(remote_ip) when is_tuple(remote_ip) do
    remote_ip
    |> normalize_ipv4_mapped_ipv6()
    |> :inet.ntoa()
    |> to_string()
  end

  def remote_ip_string(_), do: "0.0.0.0"

  defp trusted_proxy?({127, _, _, _}), do: true
  defp trusted_proxy?({10, _, _, _}), do: true
  defp trusted_proxy?({192, 168, _, _}), do: true
  defp trusted_proxy?({172, second, _, _}) when second in 16..31, do: true
  defp trusted_proxy?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp trusted_proxy?(_), do: false

  defp forwarded_for(conn) do
    conn
    |> Plug.Conn.get_req_header("x-forwarded-for")
    |> List.first()
    |> case do
      nil ->
        conn |> Plug.Conn.get_req_header("x-real-ip") |> List.first()

      header ->
        header
    end
  end

  defp forwarded_for_ip(nil), do: nil
  defp forwarded_for_ip(""), do: nil

  defp forwarded_for_ip(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    # Apache appends REMOTE_ADDR to the end, so using the right-most valid
    # entry avoids trusting client-supplied prepended values.
    |> Enum.reverse()
    |> Enum.find_value(fn ip ->
      case :inet.parse_address(String.to_charlist(ip)) do
        {:ok, tuple} -> remote_ip_string(tuple)
        _ -> nil
      end
    end)
  end

  defp normalize_ipv4_mapped_ipv6({0, 0, 0, 0, 0, 65_535, high, low}) do
    {
      Bitwise.band(Bitwise.bsr(high, 8), 0xFF),
      Bitwise.band(high, 0xFF),
      Bitwise.band(Bitwise.bsr(low, 8), 0xFF),
      Bitwise.band(low, 0xFF)
    }
  end

  defp normalize_ipv4_mapped_ipv6(tuple), do: tuple

  defp users_count(where_sql, args) do
    case Repo.query("SELECT COUNT(*) FROM users#{where_sql}", args) do
      {:ok, %{rows: [[count]]}} -> parse_positive(count, 0)
      _ -> 0
    end
  end

  defp build_user_where(params, columns) do
    class_enabled? = MapSet.member?(columns, "class")
    email_enabled? = MapSet.member?(columns, "email")
    date_enabled? = MapSet.member?(columns, "joindate")

    r_id = parse_positive(params["r_id"], 0)
    r_name = params |> Map.get("r_name", "") |> to_string() |> String.trim()
    r_email = params |> Map.get("r_email", "") |> to_string() |> String.trim()
    r_class = params |> Map.get("r_class", "") |> to_string() |> String.trim()
    r_dates = normalize_joindate(params["r_joindate"])

    {clauses, args, idx} = {[], [], 1}

    {clauses, args, idx} =
      if r_id > 0 do
        {clauses ++ ["id = $#{idx}"], args ++ [r_id], idx + 1}
      else
        {clauses, args, idx}
      end

    {clauses, args, idx} =
      if r_name != "" do
        {clauses ++ ["LOWER(name) LIKE LOWER($#{idx})"], args ++ ["%#{r_name}%"], idx + 1}
      else
        {clauses, args, idx}
      end

    {clauses, args, idx} =
      if email_enabled? and r_email != "" do
        {clauses ++ ["LOWER(email) LIKE LOWER($#{idx})"], args ++ ["%#{r_email}%"], idx + 1}
      else
        {clauses, args, idx}
      end

    {clauses, args, idx} =
      if class_enabled? and r_class != "" do
        {clauses ++ ["class = $#{idx}"], args ++ [r_class], idx + 1}
      else
        {clauses, args, idx}
      end

    {clauses, args, idx} =
      if date_enabled? and r_dates.from != "" do
        {clauses ++ ["DATE(joindate) >= $#{idx}::date"], args ++ [r_dates.from], idx + 1}
      else
        {clauses, args, idx}
      end

    {clauses, args, idx} =
      if date_enabled? and r_dates.to != "" do
        {clauses ++ ["DATE(joindate) <= $#{idx}::date"], args ++ [r_dates.to], idx + 1}
      else
        {clauses, args, idx}
      end

    where_sql =
      case clauses do
        [] -> ""
        _ -> " WHERE " <> Enum.join(clauses, " AND ")
      end

    filter_state = %{
      r_id: if(r_id > 0, do: Integer.to_string(r_id), else: ""),
      r_name: r_name,
      r_email: r_email,
      r_class: r_class,
      r_joindate: [r_dates.from, r_dates.to]
    }

    {where_sql, args, idx, filter_state}
  end

  defp normalize_joindate(value) when is_list(value) do
    from = value |> Enum.at(0, "") |> to_string()
    to = value |> Enum.at(1, "") |> to_string()
    %{from: from, to: to}
  end

  defp normalize_joindate(_), do: %{from: "", to: ""}

  defp normalize_sort(value, columns) do
    sort = value |> to_string() |> String.trim()
    email_enabled? = MapSet.member?(columns, "email")

    cond do
      sort == "name" ->
        "name"

      sort == "email" and email_enabled? ->
        "email"

      sort == "class" and MapSet.member?(columns, "class") ->
        "class"

      sort == "joindate" and MapSet.member?(columns, "joindate") ->
        "joindate"

      true ->
        "id"
    end
  end

  defp sort_order("name"), do: "LOWER(name) ASC, id DESC"
  defp sort_order("email"), do: "LOWER(COALESCE(email, '')) ASC, id DESC"
  defp sort_order("class"), do: "LOWER(class) ASC, id DESC"
  defp sort_order("joindate"), do: "joindate DESC NULLS LAST, id DESC"
  defp sort_order(_), do: "id DESC"

  defp list_classes(columns) do
    cond do
      not MapSet.member?(columns, "class") ->
        ["user"]

      use_sqlite?() ->
        sqlite_rows("SELECT DISTINCT class FROM users WHERE class IS NOT NULL ORDER BY class ASC")
        |> Enum.map(fn [value] -> to_string(value || "") end)
        |> Enum.reject(&(&1 == ""))
        |> case do
          [] -> ["admin", "anonymous", "base", "user"]
          values -> values
        end

      true ->
        case Repo.query(
               "SELECT DISTINCT class FROM users WHERE class IS NOT NULL ORDER BY class ASC",
               []
             ) do
          {:ok, %{rows: rows}} ->
            rows
            |> Enum.map(fn [value] -> to_string(value || "") end)
            |> Enum.reject(&(&1 == ""))

          _ ->
            ["admin", "anonymous", "base", "user"]
        end
    end
  end

  defp first_user_class do
    if use_sqlite?() do
      if sqlite_count("SELECT COUNT(*) FROM users WHERE class = 'admin'") == 0,
        do: "admin",
        else: "user"
    else
      case Repo.query("SELECT COUNT(*) FROM users WHERE class = 'admin'", []) do
        {:ok, %{rows: [[0]]}} -> "admin"
        _ -> "user"
      end
    end
  end

  defp next_user_id do
    if use_sqlite?() do
      sqlite_count("SELECT COALESCE(MAX(id), 0) + 1 FROM users")
    else
      case Repo.query("SELECT COALESCE(MAX(id), 0) + 1 FROM users", []) do
        {:ok, %{rows: [[value]]}} -> parse_positive(value, 1)
        _ -> 1
      end
    end
  end

  defp parse_user_id(value) do
    id = parse_positive(value, 0)
    if id > 0, do: {:ok, id}, else: {:error, :invalid_user_id}
  end

  defp user_by_id(id) when is_integer(id) and id > 0 do
    if use_sqlite?() do
      sql = "SELECT #{select_user_fields()} FROM users WHERE id = #{id} LIMIT 1"

      case sqlite_rows(sql) do
        [row | _] -> row_to_user(row)
        _ -> nil
      end
    else
      case Repo.query("SELECT #{select_user_fields()} FROM users WHERE id = $1 LIMIT 1", [id]) do
        {:ok, %{rows: [row | _]}} -> row_to_user(row)
        _ -> nil
      end
    end
  end

  defp user_by_id(_), do: nil

  defp user_by_name(name) when is_binary(name) and name != "" do
    if use_sqlite?() do
      escaped = escape_sqlite_string(name)

      sql =
        "SELECT #{select_user_fields()} FROM users WHERE LOWER(name) = LOWER('#{escaped}') LIMIT 1"

      case sqlite_rows(sql) do
        [row | _] -> row_to_user(row)
        _ -> nil
      end
    else
      case Repo.query(
             "SELECT #{select_user_fields()} FROM users WHERE LOWER(name) = LOWER($1) LIMIT 1",
             [name]
           ) do
        {:ok, %{rows: [row | _]}} -> row_to_user(row)
        _ -> nil
      end
    end
  end

  defp user_by_name(_), do: nil

  defp row_to_user([id, name, class_name, passhash, email, join_date]) do
    %{
      id: parse_positive(id, 0),
      name: to_string(name || ""),
      class: to_string(class_name || "user"),
      passhash: to_string(passhash || ""),
      email: normalize_nullable_string(email),
      join_date: to_string(join_date || "")
    }
  end

  defp select_user_fields do
    columns = user_columns()

    class_expr =
      if MapSet.member?(columns, "class"), do: "COALESCE(class, 'user')", else: "'user'"

    pass_expr = if MapSet.member?(columns, "pass"), do: "COALESCE(\"pass\", '')", else: "''"
    email_expr = if MapSet.member?(columns, "email"), do: "email", else: "NULL"

    join_expr =
      if MapSet.member?(columns, "joindate"),
        do: "COALESCE(CAST(joindate AS TEXT), '')",
        else: "''"

    "id, name, #{class_expr} AS class, #{pass_expr} AS passhash, #{email_expr} AS email, #{join_expr} AS joindate"
  end

  defp user_columns do
    if use_sqlite?() do
      case sqlite_rows("PRAGMA table_info(users)") do
        [] ->
          MapSet.new(["id", "name", "class"])

        rows ->
          rows
          |> Enum.map(fn row -> Enum.at(row, 1) |> to_string() end)
          |> MapSet.new()
      end
    else
      case Repo.query(
             "SELECT column_name FROM information_schema.columns WHERE table_schema = CURRENT_SCHEMA() AND table_name = 'users'",
             []
           ) do
        {:ok, %{rows: rows}} when rows != [] ->
          rows
          |> Enum.map(fn [value] -> to_string(value) end)
          |> MapSet.new()

        _ ->
          MapSet.new(["id", "name", "class"])
      end
    end
  end

  defp insert_user(cols, vals) do
    if use_sqlite?() do
      sql =
        "INSERT INTO users(#{Enum.join(cols, ", ")}) VALUES (" <>
          Enum.map_join(vals, ", ", &sqlite_literal/1) <> ")"

      sqlite_exec(sql)
    else
      placeholders =
        1..length(vals)
        |> Enum.map_join(", ", &"$#{&1}")

      sql = "INSERT INTO users(#{Enum.join(cols, ", ")}) VALUES (#{placeholders})"
      Repo.query(sql, vals)
    end
  end

  defp update_user_name(id, name) do
    if use_sqlite?() do
      sqlite_exec("UPDATE users SET name = #{sqlite_literal(name)} WHERE id = #{id}")
    else
      Repo.query("UPDATE users SET name = $1 WHERE id = $2", [name, id])
    end
  end

  defp update_user_password(id, hash) do
    if use_sqlite?() do
      sqlite_exec("UPDATE users SET pass = #{sqlite_literal(hash)} WHERE id = #{id}")
    else
      Repo.query("UPDATE users SET pass = $1 WHERE id = $2", [hash, id])
    end
  end

  defp update_user_email(id, address) do
    if use_sqlite?() do
      sqlite_exec("UPDATE users SET email = #{sqlite_literal(address)} WHERE id = #{id}")
    else
      Repo.query("UPDATE users SET email = $1 WHERE id = $2", [address, id])
    end
  end

  defp update_user_class(id, class_name) do
    if use_sqlite?() do
      sqlite_exec("UPDATE users SET class = #{sqlite_literal(class_name)} WHERE id = #{id}")
    else
      Repo.query("UPDATE users SET class = $1 WHERE id = $2", [class_name, id])
    end
  end

  defp delete_user_images(user_id) do
    if use_sqlite?() do
      sqlite_exec("DELETE FROM images WHERE owner_id = #{user_id}")
    else
      Repo.query("DELETE FROM images WHERE owner_id = $1", [user_id])
    end
  end

  defp reassign_user_images(user_id, anon_id) do
    if use_sqlite?() do
      sqlite_exec("UPDATE images SET owner_id = #{anon_id} WHERE owner_id = #{user_id}")
    else
      Repo.query("UPDATE images SET owner_id = $1 WHERE owner_id = $2", [anon_id, user_id])
    end
  end

  defp delete_user_comments(user_id) do
    if use_sqlite?() do
      sqlite_exec("DELETE FROM comments WHERE owner_id = #{user_id}")
    else
      Repo.query("DELETE FROM comments WHERE owner_id = $1", [user_id])
    end
  end

  defp reassign_user_comments(user_id, anon_id) do
    if use_sqlite?() do
      sqlite_exec("UPDATE comments SET owner_id = #{anon_id} WHERE owner_id = #{user_id}")
    else
      Repo.query("UPDATE comments SET owner_id = $1 WHERE owner_id = $2", [anon_id, user_id])
    end
  end

  defp delete_user_favorites(user_id) do
    if use_sqlite?() do
      sqlite_exec("DELETE FROM user_favorites WHERE user_id = #{user_id}")
    else
      Repo.query("DELETE FROM user_favorites WHERE user_id = $1", [user_id])
    end
  end

  defp delete_user_row(user_id) do
    if use_sqlite?() do
      sqlite_exec("DELETE FROM users WHERE id = #{user_id}")
    else
      Repo.query("DELETE FROM users WHERE id = $1", [user_id])
    end
  end

  defp sqlite_user_filters(params, columns) do
    r_id = parse_positive(params["r_id"], 0)
    r_name = params |> Map.get("r_name", "") |> to_string() |> String.trim()
    r_email = params |> Map.get("r_email", "") |> to_string() |> String.trim()
    r_class = params |> Map.get("r_class", "") |> to_string() |> String.trim()
    r_dates = normalize_joindate(params["r_joindate"])
    sort = normalize_sort(params["r__sort"], columns)

    clauses = []

    clauses = if r_id > 0, do: clauses ++ ["id = #{r_id}"], else: clauses

    clauses =
      if r_name != "" do
        pattern = "%" <> escape_like(r_name) <> "%"
        clauses ++ ["LOWER(name) LIKE LOWER('#{escape_sqlite_string(pattern)}') ESCAPE '\\'"]
      else
        clauses
      end

    clauses =
      if MapSet.member?(columns, "email") and r_email != "" do
        pattern = "%" <> escape_like(r_email) <> "%"
        clauses ++ ["LOWER(email) LIKE LOWER('#{escape_sqlite_string(pattern)}') ESCAPE '\\'"]
      else
        clauses
      end

    clauses =
      if MapSet.member?(columns, "class") and r_class != "" do
        clauses ++ ["class = '#{escape_sqlite_string(r_class)}'"]
      else
        clauses
      end

    clauses =
      if MapSet.member?(columns, "joindate") and r_dates.from != "" do
        clauses ++ ["DATE(joindate) >= DATE('#{escape_sqlite_string(r_dates.from)}')"]
      else
        clauses
      end

    clauses =
      if MapSet.member?(columns, "joindate") and r_dates.to != "" do
        clauses ++ ["DATE(joindate) <= DATE('#{escape_sqlite_string(r_dates.to)}')"]
      else
        clauses
      end

    where_sql =
      case clauses do
        [] -> ""
        _ -> " WHERE " <> Enum.join(clauses, " AND ")
      end

    {where_sql, sort}
  end

  defp sqlite_count(sql) do
    case sqlite_rows(sql) do
      [[value] | _] -> parse_positive(value, 0)
      _ -> 0
    end
  end

  defp use_sqlite? do
    case Site.sqlite_db_path() do
      nil -> false
      path -> File.exists?(path)
    end
  end

  defp active_backend, do: if(use_sqlite?(), do: "sqlite", else: "repo")

  defp sqlite_db_path! do
    case Site.sqlite_db_path() do
      nil -> raise "sqlite DB path is not configured"
      path -> path
    end
  end

  defp sqlite_rows(sql) do
    args = [
      "-noheader",
      "-separator",
      @sqlite_separator,
      "-newline",
      @sqlite_row_separator,
      sqlite_db_path!(),
      sql
    ]

    case System.cmd("sqlite3", args, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split(@sqlite_row_separator, trim: true)
        |> Enum.map(fn line -> String.split(line, @sqlite_separator) end)

      {error, _} ->
        Logger.warning("auth.sqlite query failed: #{String.trim(error)}")
        []
    end
  end

  defp sqlite_exec(sql) do
    case System.cmd("sqlite3", [sqlite_db_path!(), sql], stderr_to_stdout: true) do
      {_, 0} ->
        {:ok, :done}

      {error, _} ->
        Logger.warning("auth.sqlite exec failed: #{String.trim(error)}")
        {:error, :sqlite_failed}
    end
  end

  defp sqlite_literal(nil), do: "NULL"
  defp sqlite_literal(value) when is_integer(value), do: Integer.to_string(value)
  defp sqlite_literal(value) when is_float(value), do: Float.to_string(value)

  defp sqlite_literal(%NaiveDateTime{} = value),
    do: "'#{value |> NaiveDateTime.to_string() |> escape_sqlite_string()}'"

  defp sqlite_literal(value), do: "'#{escape_sqlite_string(to_string(value))}'"

  defp escape_sqlite_string(value), do: String.replace(value, "'", "''")

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp validate_username(name) do
    cond do
      name == "" ->
        {:error, :invalid_username}

      String.length(name) < 1 ->
        {:error, :invalid_username}

      Regex.match?(@username_regex, name) ->
        :ok

      true ->
        {:error, :invalid_username}
    end
  end

  defp validate_passwords(pass1, pass2) do
    cond do
      pass1 != pass2 -> {:error, :password_mismatch}
      String.length(to_string(pass1)) < 1 -> {:error, :invalid_password}
      true -> :ok
    end
  end

  defp validate_email_requirement(email) do
    if user_email_required?() and email == "" do
      {:error, :email_required}
    else
      validate_email(email)
    end
  end

  defp validate_email(""), do: :ok

  defp validate_email(address) do
    if Regex.match?(~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/, to_string(address)) do
      :ok
    else
      {:error, :invalid_email}
    end
  end

  defp ensure_username_available(name) do
    if is_nil(user_by_name(name)), do: :ok, else: {:error, :username_taken}
  end

  defp ensure_username_available_for(name, id) do
    case user_by_name(name) do
      nil -> :ok
      %{id: ^id} -> :ok
      _ -> {:error, :username_taken}
    end
  end

  defp ensure_can_edit(actor, target) do
    cond do
      is_nil(actor) -> {:error, :not_logged_in}
      actor.id == target.id -> :ok
      normalize_class(actor.class) == "admin" -> :ok
      true -> {:error, :permission_denied}
    end
  end

  defp ensure_admin(actor) do
    if actor && normalize_class(actor.class) == "admin",
      do: :ok,
      else: {:error, :permission_denied}
  end

  defp password_status(%{name: name, passhash: passhash} = user, pass)
       when is_binary(passhash) do
    legacy_md5 = md5_hex(String.downcase(name) <> pass)

    cond do
      passhash == "" ->
        :error

      passhash == legacy_md5 ->
        migrate_legacy_password(user, pass)

      String.starts_with?(passhash, "$2") ->
        if Bcrypt.verify_pass(pass, normalize_bcrypt_hash(passhash)) do
          {:ok, user}
        else
          :error
        end

      true ->
        :error
    end
  end

  defp password_status(_, _), do: :error

  defp migrate_legacy_password(user, pass) do
    new_hash = Bcrypt.hash_pwd_salt(pass)

    case update_user_password(user.id, new_hash) do
      {:ok, _} -> {:ok, %{user | passhash: new_hash}}
      _ -> {:ok, user}
    end
  end

  defp normalize_bcrypt_hash("$2y$" <> rest), do: "$2b$" <> rest
  defp normalize_bcrypt_hash(value), do: value

  defp login_throttle_key(name, remote_ip) do
    {String.downcase(String.trim(name)), to_string(remote_ip || "")}
  end

  defp login_throttle_allowed?(key) do
    table = login_throttle_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(table, key) do
      [{^key, count, first_at}]
      when now - first_at < @login_throttle_window_ms and
             count >= @login_throttle_max_failures ->
        {:error, :rate_limited}

      _ ->
        :ok
    end
  end

  defp record_login_failure(key) do
    table = login_throttle_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(table, key) do
      [{^key, count, first_at}] when now - first_at < @login_throttle_window_ms ->
        :ets.insert(table, {key, count + 1, first_at})

      _ ->
        :ets.insert(table, {key, 1, now})
    end

    :ok
  end

  defp clear_login_failures(key) do
    :ets.delete(login_throttle_table(), key)
    :ok
  end

  defp login_throttle_table do
    case :ets.whereis(@login_throttle_table) do
      :undefined ->
        ensure_login_throttle_owner()
        :ets.whereis(@login_throttle_table)

      tid ->
        tid
    end
  end

  defp ensure_login_throttle_owner do
    case Process.whereis(@login_throttle_owner) do
      nil ->
        parent = self()

        pid =
          spawn(fn ->
            try do
              :ets.new(@login_throttle_table, [
                :named_table,
                :public,
                read_concurrency: true,
                write_concurrency: true
              ])
            rescue
              ArgumentError -> :ok
            end

            send(parent, :login_throttle_ready)
            login_throttle_owner_loop()
          end)

        _ =
          try do
            Process.register(pid, @login_throttle_owner)
          rescue
            ArgumentError -> :ok
          end

        receive do
          :login_throttle_ready -> :ok
        after
          100 -> :ok
        end

      _pid ->
        :ok
    end
  end

  defp login_throttle_owner_loop do
    receive do
      :stop -> :ok
      _ -> login_throttle_owner_loop()
    end
  end

  defp valid_session?(%{passhash: passhash}, token, remote_ip) do
    token == session_id(passhash, remote_ip)
  end

  defp masked_session_ip(remote_ip) do
    case {parse_ip(remote_ip), parse_ip(session_hash_mask())} do
      {{:ok, ip}, {:ok, mask}} ->
        case {ip_to_binary(ip), ip_to_binary(mask)} do
          {ip_bin, mask_bin} when byte_size(ip_bin) == byte_size(mask_bin) ->
            binary_to_ip(binary_and(ip_bin, mask_bin))

          _ ->
            remote_ip
        end

      _ ->
        remote_ip
    end
  end

  defp parse_ip(value) do
    value
    |> to_charlist()
    |> :inet.parse_address()
  end

  defp ip_to_binary({a, b, c, d}), do: <<a, b, c, d>>

  defp ip_to_binary({a, b, c, d, e, f, g, h}) do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
  end

  defp ip_to_binary(_), do: <<>>

  defp binary_to_ip(<<a, b, c, d>>) do
    {a, b, c, d} |> :inet.ntoa() |> to_string()
  end

  defp binary_to_ip(<<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>) do
    {a, b, c, d, e, f, g, h} |> :inet.ntoa() |> to_string()
  end

  defp binary_to_ip(_), do: "0.0.0.0"

  defp binary_and(left, right) do
    left_list = :binary.bin_to_list(left)
    right_list = :binary.bin_to_list(right)

    Enum.zip(left_list, right_list)
    |> Enum.map(fn {a, b} -> band(a, b) end)
    |> :erlang.list_to_binary()
  end

  defp md5_hex(value), do: :crypto.hash(:md5, value) |> Base.encode16(case: :lower)

  defp parse_positive(value, default) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp config_int(key, default) do
    case Integer.parse(to_string(Store.get_config(key, Integer.to_string(default)) || default)) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp config_bool(key, default) do
    case Store.get_config(key, if(default, do: "Y", else: "N"))
         |> to_string()
         |> String.downcase() do
      value when value in ["1", "y", "yes", "true", "on"] -> true
      value when value in ["0", "n", "no", "false", "off"] -> false
      _ -> default
    end
  end

  defp truthy?(value) do
    to_string(value || "")
    |> String.downcase()
    |> then(&(&1 in ["1", "y", "yes", "true", "on"]))
  end

  defp normalize_class(class) do
    class
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_nullable_string(nil), do: nil
  defp normalize_nullable_string(""), do: ""
  defp normalize_nullable_string(value), do: to_string(value)
end
