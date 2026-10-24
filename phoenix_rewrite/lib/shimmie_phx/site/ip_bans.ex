defmodule ShimmiePhoenix.Site.IPBans do
  @moduledoc """
  Native IP ban management and enforcement.
  """

  import Bitwise

  alias ShimmiePhoenix.Repo
  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Cache
  alias ShimmiePhoenix.Site.Appearance
  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.Site.Users

  require Logger

  @cache_table :shimmie_ip_ban_cache
  @cache_key_active :active_bans
  @cache_ttl_ms 60_000
  @sqlite_separator <<31>>
  @sqlite_row_separator <<30>>
  @valid_modes MapSet.new(["block", "firewall", "ghost", "anon-ghost"])

  def can_manage?(%{id: id, class: class}) when is_integer(id) and id > 0 do
    normalize_mode(class) == "admin"
  end

  def can_manage?(_), do: false

  def list(limit \\ 100, opts \\ []) when is_integer(limit) do
    list_page(1, limit, opts).rows
  end

  def list_page(page, page_size \\ 100, opts \\ [])

  def list_page(page, page_size, opts) when is_integer(page) and is_integer(page_size) do
    safe_page_size = max(1, min(page_size, 1_000_000))
    include_all? = Keyword.get(opts, :include_all, false)

    total_count = count_bans(include_all?)
    total_pages = max(1, div(total_count + safe_page_size - 1, safe_page_size))
    safe_page = page |> max(1) |> min(total_pages)
    offset = (safe_page - 1) * safe_page_size
    where_sql = active_where_sql(include_all?, "b.")

    query =
      "SELECT b.id, b.ip, b.mode, COALESCE(b.reason, ''), COALESCE(CAST(b.added AS TEXT), ''), " <>
        "COALESCE(CAST(b.expires AS TEXT), ''), " <>
        "COALESCE(u.name, 'Anonymous') " <>
        "FROM bans b LEFT JOIN users u ON u.id = b.banner_id " <>
        where_sql <> " ORDER BY b.id DESC LIMIT :limit OFFSET :offset"

    %{
      rows:
        query_rows(query, %{limit: safe_page_size, offset: offset}) |> Enum.map(&row_to_ban/1),
      page: safe_page,
      page_size: safe_page_size,
      total_count: total_count,
      total_pages: total_pages,
      include_all?: include_all?
    }
  end

  def list_page(_page, page_size, opts), do: list_page(1, page_size, opts)

  def create(attrs, actor) when is_map(attrs) do
    with true <- can_manage?(actor),
         {:ok, ip} <- parse_target_ip(Map.get(attrs, "c_ip")),
         {:ok, mode} <- parse_mode(Map.get(attrs, "c_mode")),
         {:ok, expires} <- parse_expires(Map.get(attrs, "c_expires")),
         {:ok, banner_id} <- parse_actor_id(actor) do
      reason = attrs |> Map.get("c_reason", "") |> to_string() |> String.trim()

      params = %{
        id: next_id(),
        ip: ip,
        mode: mode,
        reason: reason,
        expires: expires,
        banner_id: banner_id
      }

      case insert_row(params) do
        :ok ->
          invalidate_cache()
          {:ok, ip}

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :permission_denied}
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  def create(_, _), do: {:error, :invalid_request}

  def delete(id, actor) do
    with true <- can_manage?(actor),
         {:ok, parsed_id} <- parse_positive_id(id) do
      case delete_row(parsed_id) do
        :ok ->
          invalidate_cache()
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :permission_denied}
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  def delete_many(ids, actor) when is_list(ids) do
    with true <- can_manage?(actor) do
      parsed_ids =
        ids
        |> Enum.map(&parse_positive_id/1)
        |> Enum.flat_map(fn
          {:ok, id} -> [id]
          _ -> []
        end)
        |> Enum.uniq()

      deleted =
        Enum.reduce(parsed_ids, 0, fn id, acc ->
          case delete_row(id) do
            :ok -> acc + 1
            _ -> acc
          end
        end)

      if deleted > 0 do
        invalidate_cache()
      end

      {:ok, deleted}
    else
      false -> {:error, :permission_denied}
      _ -> {:error, :invalid_request}
    end
  end

  def delete_many(_, _), do: {:error, :invalid_request}

  def evaluate_request(remote_ip, actor) do
    with {:ok, remote} <- parse_ip(remote_ip),
         ban when is_map(ban) <- find_active_ban(remote) do
      mode = normalize_mode(Map.get(ban, :mode, "block"))
      message = render_ban_message(ban)

      cond do
        mode == "ghost" ->
          {:ok, ghost_actor(actor), message}

        mode == "anon-ghost" and anonymous_actor?(actor) ->
          {:ok, ghost_actor(actor), message}

        mode in ["block", "firewall", ""] ->
          {:blocked, message}

        true ->
          {:blocked, message}
      end
    else
      _ ->
        {:ok, actor, nil}
    end
  end

  def render_ban_message(ban) when is_map(ban) do
    mode = normalize_mode(Map.get(ban, :mode, "block"))
    key = "ipban_message_#{mode}"

    base_message =
      Store.get_config(key, nil) ||
        Store.get_config(
          "ipban_message",
          "<p>IP <b>$IP</b> has been banned until <b>$DATE</b> by <b>$ADMIN</b> because of <b>$REASON</b><p>$CONTACT"
        )

    date_text =
      case Map.get(ban, :expires) do
        nil ->
          "the end of time"

        value ->
          value
          |> to_string()
          |> String.trim()
          |> case do
            "" -> "the end of time"
            trimmed -> trimmed
          end
      end

    contact =
      case Appearance.contact_href() do
        nil ->
          ""

        href ->
          "<a href=\"#{href}\">Contact the staff (be sure to include this message)</a>"
      end

    banner = Map.get(ban, :banner, "Anonymous") |> to_string()
    ip = Map.get(ban, :ip, "") |> to_string()
    reason = Map.get(ban, :reason, "") |> to_string()
    id = Map.get(ban, :id, 0) |> to_string()

    base_message
    |> to_string()
    |> String.replace("$IP", ip)
    |> String.replace("$DATE", date_text)
    |> String.replace("$ADMIN", banner)
    |> String.replace("$REASON", reason)
    |> String.replace("$CONTACT", contact)
    |> Kernel.<>("<!-- #{id} / #{mode} -->")
  end

  defp find_active_ban(remote) do
    active_bans()
    |> Enum.find(fn ban -> ip_match?(remote, Map.get(ban, :ip, "")) end)
  end

  defp active_bans do
    now = System.monotonic_time(:millisecond)

    case Cache.lookup(@cache_table, @cache_key_active) do
      [{@cache_key_active, bans, expires_at}] when expires_at > now ->
        bans

      _ ->
        bans = load_active_bans()
        Cache.insert(@cache_table, {@cache_key_active, bans, now + @cache_ttl_ms})
        bans
    end
  end

  defp load_active_bans do
    where_sql = active_where_sql(false, "b.")

    query =
      "SELECT b.id, b.ip, b.mode, COALESCE(b.reason, ''), COALESCE(CAST(b.added AS TEXT), ''), " <>
        "COALESCE(CAST(b.expires AS TEXT), ''), " <>
        "COALESCE(u.name, 'Anonymous') " <>
        "FROM bans b LEFT JOIN users u ON u.id = b.banner_id " <>
        where_sql <> " ORDER BY b.id DESC"

    query_rows(query, %{})
    |> Enum.map(&row_to_ban/1)
  end

  defp invalidate_cache do
    Cache.delete(@cache_table, @cache_key_active)
    :ok
  end

  defp insert_row(%{
         id: id,
         ip: ip,
         mode: mode,
         reason: reason,
         expires: expires,
         banner_id: banner_id
       }) do
    case sqlite_db_path() do
      nil ->
        sql =
          "INSERT INTO bans(id, ip, mode, reason, added, expires, banner_id) " <>
            "VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP, $5, $6)"

        case Repo.query(sql, [id, ip, mode, reason, expires, banner_id]) do
          {:ok, _} -> :ok
          _ -> {:error, :create_failed}
        end

      path ->
        expires_sql =
          if is_nil(expires), do: "NULL", else: sqlite_literal(NaiveDateTime.to_string(expires))

        sql =
          "INSERT INTO bans(id, ip, mode, reason, added, expires, banner_id) VALUES (" <>
            "#{id}, #{sqlite_literal(ip)}, #{sqlite_literal(mode)}, #{sqlite_literal(reason)}, " <>
            "CURRENT_TIMESTAMP, #{expires_sql}, #{banner_id})"

        sqlite_exec(path, sql)
    end
  end

  defp delete_row(id) do
    case sqlite_db_path() do
      nil ->
        case Repo.query("DELETE FROM bans WHERE id = $1", [id]) do
          {:ok, _} -> :ok
          _ -> {:error, :delete_failed}
        end

      path ->
        sqlite_exec(path, "DELETE FROM bans WHERE id = #{id}")
    end
  end

  defp next_id do
    case sqlite_db_path() do
      nil ->
        ShimmiePhoenix.IDAllocator.next!("bans")

      path ->
        ShimmiePhoenix.IDAllocator.next_sqlite!(path, "bans")
    end
  end

  defp parse_target_ip(value) do
    raw = value |> to_string() |> String.trim()

    cond do
      raw == "" ->
        {:error, :invalid_ip}

      String.contains?(raw, "/") ->
        case String.split(raw, "/", parts: 2) do
          [ip, prefix_raw] ->
            with {:ok, tuple} <- parse_ip(ip),
                 {prefix, ""} <- Integer.parse(String.trim(prefix_raw)),
                 true <- valid_prefix?(tuple, prefix) do
              {:ok, "#{ip_to_string(tuple)}/#{prefix}"}
            else
              _ -> {:error, :invalid_ip}
            end

          _ ->
            {:error, :invalid_ip}
        end

      true ->
        case parse_ip(raw) do
          {:ok, tuple} -> {:ok, ip_to_string(tuple)}
          _ -> {:error, :invalid_ip}
        end
    end
  end

  defp parse_mode(value) do
    mode = value |> to_string() |> String.trim() |> normalize_mode()
    if MapSet.member?(@valid_modes, mode), do: {:ok, mode}, else: {:ok, "block"}
  end

  defp parse_expires(nil), do: {:ok, nil}

  defp parse_expires(value) do
    raw = value |> to_string() |> String.trim()

    cond do
      raw == "" ->
        {:ok, nil}

      true ->
        parse_relative_expires(raw)
    end
  end

  defp parse_relative_expires(raw) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    case Regex.run(~r/^\+?\s*(\d+)\s*(minute|minutes|hour|hours|day|days|week|weeks)$/i, raw) do
      [_, n_raw, unit] ->
        {n, ""} = Integer.parse(n_raw)
        seconds = interval_seconds(n, String.downcase(unit))
        {:ok, NaiveDateTime.add(now, seconds, :second)}

      _ ->
        case NaiveDateTime.from_iso8601(raw) do
          {:ok, dt} ->
            {:ok, NaiveDateTime.truncate(dt, :second)}

          _ ->
            case Date.from_iso8601(raw) do
              {:ok, date} ->
                {:ok, NaiveDateTime.new!(date, ~T[00:00:00])}

              _ ->
                {:error, :invalid_expiry}
            end
        end
    end
  end

  defp interval_seconds(n, unit) when unit in ["minute", "minutes"], do: n * 60
  defp interval_seconds(n, unit) when unit in ["hour", "hours"], do: n * 3600
  defp interval_seconds(n, unit) when unit in ["day", "days"], do: n * 86_400
  defp interval_seconds(n, unit) when unit in ["week", "weeks"], do: n * 604_800
  defp interval_seconds(n, _), do: n * 604_800

  defp parse_actor_id(%{id: id}) when is_integer(id) and id > 0, do: {:ok, id}
  defp parse_actor_id(_), do: {:error, :permission_denied}

  defp parse_positive_id(value) do
    case Integer.parse(to_string(value || "")) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_id}
    end
  end

  defp row_to_ban([id, ip, mode, reason, added, expires, banner]) do
    %{
      id: parse_int(id),
      ip: to_string(ip || ""),
      mode: normalize_mode(to_string(mode || "block")),
      reason: to_string(reason || ""),
      added: to_string(added || ""),
      expires: to_string(expires || ""),
      banner: to_string(banner || "Anonymous")
    }
  end

  defp row_to_ban(_), do: %{id: 0, ip: "", mode: "block", reason: "", added: "", expires: ""}

  defp normalize_mode(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp anonymous_actor?(nil), do: true

  defp anonymous_actor?(%{id: id, class: class}) do
    id == Users.anonymous_id() or normalize_mode(class) == "anonymous"
  end

  defp anonymous_actor?(_), do: true

  defp ghost_actor(nil), do: %{id: Users.anonymous_id(), name: "Anonymous", class: "ghost"}
  defp ghost_actor(actor) when is_map(actor), do: Map.put(actor, :class, "ghost")
  defp ghost_actor(_), do: %{id: Users.anonymous_id(), name: "Anonymous", class: "ghost"}

  defp valid_prefix?({_a, _b, _c, _d}, prefix), do: prefix >= 0 and prefix <= 32
  defp valid_prefix?({_a, _b, _c, _d, _e, _f, _g, _h}, prefix), do: prefix >= 0 and prefix <= 128
  defp valid_prefix?(_, _), do: false

  defp ip_match?(remote, target) do
    target = to_string(target || "") |> String.trim()

    cond do
      target == "" ->
        false

      String.contains?(target, "/") ->
        match_cidr?(remote, target)

      true ->
        case parse_ip(target) do
          {:ok, target_ip} -> target_ip == remote
          _ -> false
        end
    end
  end

  defp match_cidr?(remote, cidr) do
    case String.split(cidr, "/", parts: 2) do
      [base_raw, prefix_raw] ->
        with {:ok, base} <- parse_ip(base_raw),
             {prefix, ""} <- Integer.parse(String.trim(prefix_raw)),
             true <- valid_prefix?(base, prefix),
             {:ok, remote_bin} <- ip_to_binary(remote),
             {:ok, base_bin} <- ip_to_binary(base),
             true <- byte_size(remote_bin) == byte_size(base_bin) do
          compare_prefix(remote_bin, base_bin, prefix)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp compare_prefix(_left, _right, 0), do: true

  defp compare_prefix(left, right, prefix_bits) do
    bytes = div(prefix_bits, 8)
    rem_bits = rem(prefix_bits, 8)

    left_prefix = binary_part(left, 0, bytes)
    right_prefix = binary_part(right, 0, bytes)

    cond do
      left_prefix != right_prefix ->
        false

      rem_bits == 0 ->
        true

      true ->
        <<left_next, _::binary>> = binary_part(left, bytes, 1)
        <<right_next, _::binary>> = binary_part(right, bytes, 1)
        mask = 0xFF <<< (8 - rem_bits) &&& 0xFF
        (left_next &&& mask) == (right_next &&& mask)
    end
  end

  defp parse_ip(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.to_charlist()
    |> :inet.parse_address()
  end

  defp ip_to_binary({a, b, c, d}), do: {:ok, <<a, b, c, d>>}

  defp ip_to_binary({a, b, c, d, e, f, g, h}) do
    {:ok, <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>}
  end

  defp ip_to_binary(_), do: :error

  defp ip_to_string(ip), do: ip |> :inet.ntoa() |> to_string()

  defp parse_int(value) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp query_rows(sql, params) when is_binary(sql) and is_map(params) do
    case sqlite_db_path() do
      nil -> query_rows_repo(sql, params)
      path -> query_rows_sqlite(path, sql, params)
    end
  end

  defp query_rows_repo(sql, params) do
    ordered =
      params
      |> Map.to_list()
      |> Enum.sort_by(fn {k, _} -> k end)

    compiled_sql =
      ordered
      |> Enum.with_index(1)
      |> Enum.reduce(sql, fn {{key, _}, idx}, acc -> String.replace(acc, ":#{key}", "$#{idx}") end)

    args = Enum.map(ordered, fn {_, value} -> value end)

    case Repo.query(compiled_sql, args) do
      {:ok, %{rows: rows}} -> rows
      _ -> []
    end
  end

  defp query_rows_sqlite(path, sql, params) do
    compiled_sql =
      Enum.reduce(params, sql, fn {key, value}, acc ->
        String.replace(acc, ":#{key}", sqlite_literal(value))
      end)

    sqlite_rows(path, compiled_sql)
  end

  defp sqlite_db_path do
    case Site.sqlite_db_path() do
      nil -> nil
      path -> if File.exists?(path), do: path, else: nil
    end
  end

  defp sqlite_rows(path, query) do
    args = [
      "-noheader",
      "-separator",
      @sqlite_separator,
      "-newline",
      @sqlite_row_separator,
      path,
      query
    ]

    case System.cmd("sqlite3", args, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split(@sqlite_row_separator, trim: true)
        |> Enum.map(&String.split(&1, @sqlite_separator))

      {error, _} ->
        Logger.warning("ip_bans.sqlite query failed: #{String.trim(error)}")
        []
    end
  end

  defp sqlite_single(path, query) do
    case sqlite_rows(path, query) do
      [[value | _] | _] -> value
      _ -> nil
    end
  end

  defp sqlite_exec(path, query) do
    case System.cmd("sqlite3", [path, query], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {error, _} ->
        Logger.warning("ip_bans.sqlite exec failed: #{String.trim(error)}")
        {:error, :sqlite_failed}
    end
  end

  defp sqlite_literal(value) when is_integer(value), do: Integer.to_string(value)
  defp sqlite_literal(value) when is_float(value), do: Float.to_string(value)
  defp sqlite_literal(value), do: "'" <> escape_sqlite_string(to_string(value || "")) <> "'"

  defp escape_sqlite_string(value), do: String.replace(value, "'", "''")

  defp count_bans(include_all?) do
    where_sql = active_where_sql(include_all?)

    case query_rows("SELECT COUNT(*) FROM bans " <> where_sql, %{}) do
      [[count]] -> parse_int(count)
      _ -> 0
    end
  end

  defp active_where_sql(true), do: ""
  defp active_where_sql(false), do: "WHERE (expires IS NULL OR expires > CURRENT_TIMESTAMP)"
  defp active_where_sql(true, _prefix), do: ""

  defp active_where_sql(false, prefix) when is_binary(prefix) do
    "WHERE (#{prefix}expires IS NULL OR #{prefix}expires > CURRENT_TIMESTAMP)"
  end
end
