defmodule ShimmiePhoenix.Site.Users do
  @moduledoc "Legacy-compatible user/account helpers for /user_admin routes.\n"

  import Bitwise
  require Logger

  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.Repo
  alias ShimmiePhoenix.{AuthThrottle, PasswordPolicy}

  @username_regex ~r/^[a-zA-Z0-9\-_]+$/
  @site_user_id_key :site_user_id
  @site_user_name_key :site_user_name
  @legacy_user_id_key :legacy_user_id
  @legacy_user_name_key :legacy_user_name
  @session_proof_key :site_session_proof_v2
  @session_salt "account-session-v2"
  @legacy_salt "legacy-session-v2"
  alias ShimmiePhoenixWeb.Endpoint

  def signup_enabled? do
    config_bool("login_signup_enabled", true)
  end

  def user_email_required? do
    config_bool("user_email_required", false)
  end

  def login_redirect_mode do
    to_string(Store.get_config("user_login_redirect", "previous") || "previous")
  end

  def login_memory_days do
    config_int("login_memory", 365)
  end

  def session_hash_mask do
    to_string(Store.get_config("session_hash_mask", "255.255.0.0") || "255.255.0.0")
  end

  def recaptcha_site_key do
    to_string(Store.get_config("api_recaptcha_pubkey", "") || "")
  end

  def anonymous_id do
    config_int("anon_id", 1)
  end

  def current_user(conn) do
    case raw_session_user_id(conn) do
      id when is_integer(id) and id > 0 ->
        user = user_by_id(id)

        if valid_proof?(user, Plug.Conn.get_session(conn, @session_proof_key), @session_salt) do
          user
        end

      _ ->
        conn = Plug.Conn.fetch_cookies(conn)
        name = conn.cookies["shm_user"] || conn.cookies["user"]
        token = conn.cookies["shm_session"] || conn.cookies["session"]

        if is_binary(name) and name != "" and is_binary(token) and token != "" do
          case user_by_name(name) do
            nil ->
              nil

            user ->
              if valid_session?(user, token, remote_ip_string(conn)) do
                user
              else
                nil
              end
          end
        else
          nil
        end
    end
  end

  def session_user_id(conn) do
    case current_user(conn) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp raw_session_user_id(conn) do
    case Plug.Conn.get_session(conn, @site_user_id_key) ||
           Plug.Conn.get_session(conn, @legacy_user_id_key) do
      id when is_integer(id) and id > 0 -> id
      _ -> nil
    end
  end

  def session_user_name(conn) do
    case current_user(conn) do
      %{name: name} -> name
      _ -> nil
    end
  end

  def put_user_session(conn, %{id: id, name: name} = user)
      when is_integer(id) and is_binary(name) do
    proof = Phoenix.Token.sign(Endpoint, @session_salt, proof_payload(user))

    conn
    |> Plug.Conn.put_session(@site_user_id_key, id)
    |> Plug.Conn.put_session(@legacy_user_id_key, id)
    |> Plug.Conn.put_session(@session_proof_key, proof)
    |> put_user_name_session(name)
  end

  def put_user_name_session(conn, name) when is_binary(name) do
    conn
    |> Plug.Conn.put_session(@site_user_name_key, name)
    |> Plug.Conn.put_session(@legacy_user_name_key, name)
  end

  def get_user_by_id(id) when is_integer(id) and id > 0 do
    user_by_id(id)
  end

  def get_user_by_id(_) do
    nil
  end

  def get_user_by_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    user_by_name(trimmed) ||
      user_by_name(String.replace(trimmed, " ", "_")) ||
      user_by_name(String.replace(trimmed, "_", " "))
  end

  def get_user_by_name(_) do
    nil
  end

  def login(name, pass, remote_ip) when is_binary(name) and is_binary(pass) do
    with true <- byte_size(name) <= 256 and byte_size(pass) <= 4096,
         :ok <- AuthThrottle.check(:login, remote_ip, name) do
      authenticate(name, pass, remote_ip)
    else
      false -> {:error, :invalid_credentials}
      error -> error
    end
  end

  def login(_, _, _) do
    {:error, :invalid_credentials}
  end

  defp authenticate(name, pass, remote_ip) do
    backend = "repo"

    case user_by_name(String.trim(name)) ||
           user_by_name(String.replace(String.trim(name), " ", "_")) do
      nil ->
        Bcrypt.no_user_verify()
        Logger.warning("auth.login failure backend=#{backend}")

        {:error, :invalid_credentials}

      user ->
        if valid_password?(user, pass) do
          Logger.info("auth.login success backend=#{backend}")

          with {:ok, user} <- upgrade_legacy_password(user, pass) do
            {:ok, user, session_id(user, remote_ip)}
          end
        else
          Logger.warning("auth.login failure backend=#{backend}")

          {:error, :invalid_credentials}
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
         :ok <- AuthThrottle.check(:signup, remote_ip, name),
         :ok <- ensure_username_available(name),
         :ok <- validate_passwords(pass1, pass2),
         :ok <- validate_email_requirement(email) do
      class_name =
        Map.get(opts, :class) ||
          if(MapSet.member?(columns, "class")) do
            "user"
          else
            nil
          end

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
          value =
            if(email == "") do
              nil
            else
              email
            end

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
              {:ok, user, session_id(user, remote_ip)}

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

          if parsed > 0 do
            Integer.to_string(parsed)
          else
            ""
          end
        end),
      r_name: params |> Map.get("r_name", "") |> to_string() |> String.trim(),
      r_email: params |> Map.get("r_email", "") |> to_string() |> String.trim(),
      r_class: params |> Map.get("r_class", "") |> to_string() |> String.trim(),
      r_joindate: [r_dates.from, r_dates.to]
    }

    list_users_repo(params, columns, page_size, page)
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

  def recover(_username) do
    {:error, :recovery_unavailable}
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
         :ok <- AuthThrottle.check(:password_change, remote_ip, user.id),
         :ok <- validate_passwords(Map.get(params, "pass1", ""), Map.get(params, "pass2", "")),
         true <- MapSet.member?(user_columns(), "pass"),
         {:ok, _} <-
           update_user_password(user.id, Bcrypt.hash_pwd_salt(Map.get(params, "pass1", ""))) do
      refreshed = user_by_id(user.id)
      {:ok, refreshed, session_id(refreshed, remote_ip)}
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
    ShimmiePhoenix.Mutation.atomic(fn -> do_delete_user(actor, params) end)
  end

  defp do_delete_user(actor, params) do
    with :ok <- ensure_admin(actor),
         {:ok, user_id} <- parse_user_id(params["id"]),
         user when not is_nil(user) <- user_by_id(user_id),
         false <- user.id == anonymous_id() do
      with_images = truthy?(Map.get(params, "with_images"))
      with_comments = truthy?(Map.get(params, "with_comments"))
      anon = anonymous_id()

      image_action =
        if with_images do
          &delete_user_images/1
        else
          &reassign_user_images(&1, anon)
        end

      comment_action =
        if with_comments do
          &delete_user_comments/1
        else
          &reassign_user_comments(&1, anon)
        end

      with {:ok, _} <- image_action.(user.id),
           {:ok, _} <- comment_action.(user.id),
           {:ok, _} <- delete_user_favorites(user.id),
           {:ok, _} <- delete_user_row(user.id) do
        {:ok, :deleted}
      else
        _ -> {:error, :delete_failed}
      end
    else
      {:error, _} = err -> err
      nil -> {:error, :user_not_found}
      true -> {:error, :cannot_delete_anon}
      _ -> {:error, :delete_failed}
    end
  end

  def session_id(%{id: id} = user, remote_ip) when is_integer(id) and is_binary(remote_ip) do
    payload = Map.put(proof_payload(user), :subnet, masked_session_ip(remote_ip))
    "v2." <> Phoenix.Token.sign(Endpoint, @legacy_salt, payload)
  end

  defp proof_payload(user) do
    %{id: user.id, credential: credential_stamp(Map.get(user, :passhash))}
  end

  defp credential_stamp(passhash) do
    :crypto.mac(
      :hmac,
      :sha256,
      Endpoint.config(:secret_key_base),
      "account-credential-v2:" <> to_string(passhash || "")
    )
    |> Base.url_encode64(padding: false)
  end

  defp session_max_age do
    max(60, min(max(login_memory_days(), 0), 365) * 86400)
  end

  defp valid_proof?(%{id: id} = user, token, salt)
       when is_binary(token) and byte_size(token) < 4096 do
    with {:ok, %{id: ^id, credential: credential}} <-
           Phoenix.Token.verify(Endpoint, salt, token, max_age: session_max_age()),
         true <- is_binary(credential) do
      Plug.Crypto.secure_compare(credential, credential_stamp(Map.get(user, :passhash)))
    else
      _ -> false
    end
  end

  defp valid_proof?(_, _, _) do
    false
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

  def remote_ip_string(_) do
    "0.0.0.0"
  end

  defp trusted_proxy?({127, _, _, _}) do
    true
  end

  defp trusted_proxy?({10, _, _, _}) do
    true
  end

  defp trusted_proxy?({192, 168, _, _}) do
    true
  end

  defp trusted_proxy?({172, second, _, _}) when second in 16..31 do
    true
  end

  defp trusted_proxy?({0, 0, 0, 0, 0, 0, 0, 1}) do
    true
  end

  defp trusted_proxy?(_) do
    false
  end

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

  defp forwarded_for_ip(nil) do
    nil
  end

  defp forwarded_for_ip("") do
    nil
  end

  defp forwarded_for_ip(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.find_value(fn ip ->
      case :inet.parse_address(String.to_charlist(ip)) do
        {:ok, tuple} -> remote_ip_string(tuple)
        _ -> nil
      end
    end)
  end

  defp normalize_ipv4_mapped_ipv6({0, 0, 0, 0, 0, 65535, high, low}) do
    {
      Bitwise.band(Bitwise.bsr(high, 8), 255),
      Bitwise.band(high, 255),
      Bitwise.band(Bitwise.bsr(low, 8), 255),
      Bitwise.band(low, 255)
    }
  end

  defp normalize_ipv4_mapped_ipv6(tuple) do
    tuple
  end

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
      r_id:
        if(r_id > 0) do
          Integer.to_string(r_id)
        else
          ""
        end,
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

  defp normalize_joindate(_) do
    %{from: "", to: ""}
  end

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

  defp sort_order("name") do
    "LOWER(name) ASC, id DESC"
  end

  defp sort_order("email") do
    "LOWER(COALESCE(email, '')) ASC, id DESC"
  end

  defp sort_order("class") do
    "LOWER(class) ASC, id DESC"
  end

  defp sort_order("joindate") do
    "joindate DESC NULLS LAST, id DESC"
  end

  defp sort_order(_) do
    "id DESC"
  end

  defp list_classes(columns) do
    cond do
      not MapSet.member?(columns, "class") ->
        ["user"]

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

  defp next_user_id do
    ShimmiePhoenix.IDAllocator.next!("users")
  end

  defp parse_user_id(value) do
    id = parse_positive(value, 0)

    if id > 0 do
      {:ok, id}
    else
      {:error, :invalid_user_id}
    end
  end

  defp user_by_id(id) when is_integer(id) and id > 0 do
    case Repo.query("SELECT #{select_user_fields()} FROM users WHERE id = $1 LIMIT 1", [id]) do
      {:ok, %{rows: [row | _]}} -> row_to_user(row)
      _ -> nil
    end
  end

  defp user_by_id(_) do
    nil
  end

  defp user_by_name(name) when is_binary(name) and name != "" do
    case Repo.query(
           "SELECT #{select_user_fields()} FROM users WHERE LOWER(name) = LOWER($1) LIMIT 1",
           [name]
         ) do
      {:ok, %{rows: [row | _]}} -> row_to_user(row)
      _ -> nil
    end
  end

  defp user_by_name(_) do
    nil
  end

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
      if MapSet.member?(columns, "class") do
        "COALESCE(class, 'user')"
      else
        "'user'"
      end

    pass_expr =
      if MapSet.member?(columns, "pass") do
        "COALESCE(\"pass\", '')"
      else
        "''"
      end

    email_expr =
      if MapSet.member?(columns, "email") do
        "email"
      else
        "NULL"
      end

    join_expr =
      if MapSet.member?(columns, "joindate") do
        "COALESCE(CAST(joindate AS TEXT), '')"
      else
        "''"
      end

    "id, name, #{class_expr} AS class, #{pass_expr} AS passhash, #{email_expr} AS email, #{join_expr} AS joindate"
  end

  defp user_columns do
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

  defp insert_user(cols, vals) do
    placeholders =
      1..length(vals)
      |> Enum.map_join(", ", &"$#{&1}")

    sql = "INSERT INTO users(#{Enum.join(cols, ", ")}) VALUES (#{placeholders})"
    Repo.query(sql, vals)
  end

  defp update_user_name(id, name) do
    Repo.query("UPDATE users SET name = $1 WHERE id = $2", [name, id])
  end

  defp update_user_password(id, hash) do
    Repo.query("UPDATE users SET pass = $1 WHERE id = $2", [hash, id])
  end

  defp update_user_email(id, address) do
    Repo.query("UPDATE users SET email = $1 WHERE id = $2", [address, id])
  end

  defp update_user_class(id, class_name) do
    Repo.query("UPDATE users SET class = $1 WHERE id = $2", [class_name, id])
  end

  defp delete_user_images(user_id) do
    Repo.query("DELETE FROM images WHERE owner_id = $1", [user_id])
  end

  defp reassign_user_images(user_id, anon_id) do
    Repo.query("UPDATE images SET owner_id = $1 WHERE owner_id = $2", [anon_id, user_id])
  end

  defp delete_user_comments(user_id) do
    Repo.query("DELETE FROM comments WHERE owner_id = $1", [user_id])
  end

  defp reassign_user_comments(user_id, anon_id) do
    Repo.query("UPDATE comments SET owner_id = $1 WHERE owner_id = $2", [anon_id, user_id])
  end

  defp delete_user_favorites(user_id) do
    Repo.query("DELETE FROM user_favorites WHERE user_id = $1", [user_id])
  end

  defp delete_user_row(user_id) do
    Repo.query("DELETE FROM users WHERE id = $1", [user_id])
  end

  defp validate_username(name) do
    cond do
      name == "" ->
        {:error, :invalid_username}

      byte_size(name) > 256 ->
        {:error, :invalid_username}

      Regex.match?(@username_regex, name) ->
        :ok

      true ->
        {:error, :invalid_username}
    end
  end

  defp validate_passwords(pass1, pass2) do
    PasswordPolicy.validate(pass1, pass2)
  end

  defp validate_email_requirement(email) do
    if user_email_required?() and email == "" do
      {:error, :email_required}
    else
      validate_email(email)
    end
  end

  defp validate_email("") do
    :ok
  end

  defp validate_email(address) do
    if Regex.match?(~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/, to_string(address)) do
      :ok
    else
      {:error, :invalid_email}
    end
  end

  defp ensure_username_available(name) do
    if is_nil(user_by_name(name)) do
      :ok
    else
      {:error, :username_taken}
    end
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
    if actor && normalize_class(actor.class) == "admin" do
      :ok
    else
      {:error, :permission_denied}
    end
  end

  defp valid_password?(%{name: name, passhash: passhash}, pass) when is_binary(passhash) do
    legacy_md5 = md5_hex(String.downcase(name) <> pass)

    cond do
      passhash == "" ->
        false

      Plug.Crypto.secure_compare(passhash, legacy_md5) ->
        true

      String.starts_with?(passhash, "$2") ->
        Bcrypt.verify_pass(pass, normalize_bcrypt_hash(passhash))

      true ->
        false
    end
  rescue
    _ -> false
  end

  defp valid_password?(_, _) do
    false
  end

  defp upgrade_legacy_password(%{passhash: "$2" <> _} = user, _pass) do
    {:ok, user}
  end

  defp upgrade_legacy_password(_user, pass) when byte_size(pass) > 72 do
    {:error, :password_upgrade_required}
  end

  defp upgrade_legacy_password(user, pass) do
    hash = Bcrypt.hash_pwd_salt(pass)

    result =
      Repo.query("UPDATE users SET pass=$1 WHERE id=$2 AND pass=$3", [
        hash,
        user.id,
        user.passhash
      ])

    with {:ok, _} <- result,
         %{passhash: ^hash} = refreshed <- user_by_id(user.id) do
      {:ok, refreshed}
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  defp normalize_bcrypt_hash("$2y$" <> rest) do
    "$2b$" <> rest
  end

  defp normalize_bcrypt_hash(value) do
    value
  end

  defp valid_session?(user, "v2." <> token, remote_ip) do
    with true <- valid_proof?(user, token, @legacy_salt),
         {:ok, %{subnet: subnet}} <-
           Phoenix.Token.verify(Endpoint, @legacy_salt, token, max_age: session_max_age()) do
      subnet == masked_session_ip(remote_ip)
    else
      _ -> false
    end
  end

  defp valid_session?(_, _, _) do
    false
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

  defp ip_to_binary({a, b, c, d}) do
    <<a, b, c, d>>
  end

  defp ip_to_binary({a, b, c, d, e, f, g, h}) do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
  end

  defp ip_to_binary(_) do
    <<>>
  end

  defp binary_to_ip(<<a, b, c, d>>) do
    {a, b, c, d} |> :inet.ntoa() |> to_string()
  end

  defp binary_to_ip(<<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>) do
    {a, b, c, d, e, f, g, h} |> :inet.ntoa() |> to_string()
  end

  defp binary_to_ip(_) do
    "0.0.0.0"
  end

  defp binary_and(left, right) do
    left_list = :binary.bin_to_list(left)
    right_list = :binary.bin_to_list(right)

    Enum.zip(left_list, right_list)
    |> Enum.map(fn {a, b} -> band(a, b) end)
    |> :erlang.list_to_binary()
  end

  defp md5_hex(value) do
    :crypto.hash(:md5, value) |> Base.encode16(case: :lower)
  end

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
    case Store.get_config(
           key,
           if(default) do
             "Y"
           else
             "N"
           end
         )
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

  defp normalize_nullable_string(nil) do
    nil
  end

  defp normalize_nullable_string("") do
    ""
  end

  defp normalize_nullable_string(value) do
    to_string(value)
  end
end
