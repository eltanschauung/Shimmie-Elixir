defmodule ShimmiePhoenixWeb.LegacyPagesController do
  use ShimmiePhoenixWeb, :controller

  alias ShimmiePhoenix.Site
  alias ShimmiePhoenix.Site.Comments
  alias ShimmiePhoenix.Site.Index
  alias ShimmiePhoenix.Site.IPBans
  alias ShimmiePhoenix.Site.Pages
  alias ShimmiePhoenix.Site.Permissions
  alias ShimmiePhoenix.Site.PrivateMessages
  alias ShimmiePhoenix.Site.Posts
  alias ShimmiePhoenix.Site.Approval
  alias ShimmiePhoenix.Site.TelegramAlerts
  alias ShimmiePhoenix.Site.UserProfile
  alias ShimmiePhoenix.Site.Help
  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.Site.TagEdit
  alias ShimmiePhoenix.Site.Upload
  alias ShimmiePhoenix.Site.Users
  alias ShimmiePhoenix.Repo

  def comment_list(conn, params) do
    page = parse_page(params["page_num"])
    per_page = 10
    {threads, total_count} = Pages.list_comment_threads(page, per_page)
    total_pages = max(1, div(total_count + per_page - 1, per_page))
    current_page = min(page, total_pages)
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)
    remote_ip = Users.remote_ip_string(conn)
    can_create_comments = Comments.can_create_comment?(current_user)
    comment_captcha? = String.upcase(to_string(Store.get_config("comment_captcha", "N"))) == "Y"

    show_inline_postbox? =
      can_create_comments and (Comments.bypass_comment_checks?(current_user) or not comment_captcha?)

    conn
    |> assign(:page_title, "#{Pages.site_title()} - Comments")
    |> render(:comment_list,
      threads: threads,
      can_create_comments: can_create_comments,
      show_inline_postbox?: show_inline_postbox?,
      comment_form_hash: Comments.form_hash(remote_ip),
      can_delete_comments: Comments.can_delete_comment?(current_user),
      can_view_comment_ips: Comments.can_view_ip?(current_user),
      can_ban_comment_ips: Comments.can_ban_ip?(current_user),
      page: current_page,
      total_pages: total_pages,
      paginator_items: paginator_items(current_page, total_pages),
      prev_path: if(current_page > 1, do: "/comment/list/#{current_page - 1}", else: nil),
      next_path:
        if(current_page < total_pages, do: "/comment/list/#{current_page + 1}", else: nil)
    )
  end

  def upload(conn, _params) do
    rows = Enum.to_list(0..(Pages.upload_count() - 1))

    conn
    |> assign(:page_title, "#{Pages.site_title()} - Upload")
    |> render(:upload,
      rows: rows,
      max_upload_size: human_filesize(Pages.upload_max_size()),
      notice: conn.params["notice"],
      error: conn.params["error"]
    )
  end

  def upload_post(conn, params) do
    actor = conn.assigns[:legacy_user] || Users.current_user(conn) || anonymous_actor()
    remote_ip = Users.remote_ip_string(conn)
    common_tags = params["tags"]
    common_source = params["source"]
    entries = upload_entries(params)

    cond do
      not Upload.can_upload?(actor) ->
        redirect(conn,
          to:
            "/upload?error=" <>
              URI.encode_www_form(Upload.upload_denied_message(actor))
        )

      entries == [] ->
        redirect(conn, to: "/upload?error=" <> URI.encode_www_form("No files selected"))

      true ->
        {oks, errors} =
          Enum.reduce(entries, {[], []}, fn entry, {ok_acc, err_acc} ->
            row = entry.row
            row_tags = Map.get(params, "tags#{row}")
            row_source = Map.get(params, "url#{row}")

            result =
              case entry do
                %{kind: :file, upload: upload} ->
                  Upload.create_file_upload(
                    upload,
                    actor,
                    remote_ip,
                    common_tags,
                    row_tags,
                    common_source,
                    row_source
                  )

                %{kind: :url, url: url} ->
                  Upload.create_url_upload(
                    url,
                    actor,
                    remote_ip,
                    common_tags,
                    row_tags,
                    common_source,
                    row_source
                  )
              end

            case result do
              {:ok, image_id} ->
                post_tags =
                  case Posts.get_post(image_id) do
                    %{tags: tags} when is_list(tags) -> tags
                    _ -> []
                  end

                approved? = Approval.image_approved?(image_id)
                _ = TelegramAlerts.notify_post_uploaded(image_id, actor, post_tags, approved?)
                {[image_id | ok_acc], err_acc}

              {:error, reason} ->
                {ok_acc, [reason | err_acc]}
            end
          end)

        case {Enum.reverse(oks), Enum.reverse(errors)} do
          {[], reasons} ->
            message =
              reasons
              |> Enum.uniq()
              |> Enum.map(&upload_error_message/1)
              |> Enum.join("; ")

            redirect(conn, to: "/upload?error=" <> URI.encode_www_form(message))

          {[single], []} ->
            redirect(conn, to: "/post/view/#{single}")

          {ids, []} ->
            redirect(
              conn,
              to:
                "/post/list?notice=" <>
                  URI.encode_www_form("Uploaded #{length(ids)} files")
            )

          {ids, reasons} ->
            message =
              reasons
              |> Enum.uniq()
              |> Enum.map(&upload_error_message/1)
              |> Enum.join("; ")

            redirect(
              conn,
              to:
                "/post/list?notice=" <>
                  URI.encode_www_form("Uploaded #{length(ids)} files") <>
                  "&error=" <> URI.encode_www_form(message)
            )
        end
    end
  end

  def tags_root(conn, _params), do: redirect(conn, to: "/tags/map")

  def tags(conn, %{"sub" => "map"} = params) do
    starts_with = params["starts_with"]
    tags = Pages.tags_map_data(starts_with)
    letters = Pages.tag_az_letters()

    conn
    |> assign(:page_title, "#{Pages.site_title()} - Tag List")
    |> render(:tags_map, tags: tags, letters: letters)
  end

  def tags(conn, %{"sub" => "alphabetic"} = params) do
    starts_with = params["starts_with"]
    groups = Pages.tags_alphabetic(starts_with)
    letters = Pages.tag_az_letters()

    conn
    |> assign(:page_title, "#{Pages.site_title()} - Tag List")
    |> render(:tags_alphabetic, groups: groups, letters: letters)
  end

  def tags(conn, %{"sub" => "popularity"}) do
    groups = Pages.tags_popularity()

    conn
    |> assign(:page_title, "#{Pages.site_title()} - Tag List")
    |> render(:tags_popularity, groups: groups)
  end

  def tags(conn, %{"sub" => _}), do: send_resp(conn, 404, "Not Found")

  def auto_tag_list(conn, params) do
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)

    conn
    |> assign(:page_title, "#{Pages.site_title()} - Auto-Tag")
    |> assign(:has_left_nav, true)
    |> render(:auto_tag_list,
      rows: Pages.list_auto_tags(1_000),
      can_manage?: can_manage_tag_lists?(current_user),
      notice: params["notice"],
      error: params["error"]
    )
  end

  def auto_tag_add(conn, params) do
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)

    if can_manage_tag_lists?(current_user) do
      tag = params["c_tag"] |> to_string() |> String.trim()
      additional = params["c_additional_tags"] |> to_string() |> String.trim()

      case Pages.add_auto_tag(tag, additional) do
        :ok ->
          redirect(conn, to: "/auto_tag/list?notice=" <> URI.encode_www_form("Auto-tag saved"))

        {:error, :invalid_tag} ->
          redirect(conn, to: "/auto_tag/list?error=" <> URI.encode_www_form("Tag is required"))

        {:error, :invalid_additional_tags} ->
          redirect(
            conn,
            to: "/auto_tag/list?error=" <> URI.encode_www_form("Additional tags are required")
          )

        _ ->
          redirect(conn, to: "/auto_tag/list?error=" <> URI.encode_www_form("Unable to save rule"))
      end
    else
      send_resp(conn, 403, "Permission Denied")
    end
  end

  def auto_tag_remove(conn, params) do
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)

    if can_manage_tag_lists?(current_user) do
      tag = params["d_tag"] |> to_string() |> String.trim()

      case Pages.remove_auto_tag(tag) do
        :ok ->
          redirect(conn, to: "/auto_tag/list?notice=" <> URI.encode_www_form("Auto-tag removed"))

        _ ->
          redirect(conn,
            to: "/auto_tag/list?error=" <> URI.encode_www_form("Unable to remove rule")
          )
      end
    else
      send_resp(conn, 403, "Permission Denied")
    end
  end

  def alias_list(conn, params) do
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)

    conn
    |> assign(:page_title, "#{Pages.site_title()} - Aliases")
    |> assign(:has_left_nav, true)
    |> render(:alias_list,
      rows: Pages.list_aliases(1_000),
      can_manage?: can_manage_tag_lists?(current_user),
      notice: params["notice"],
      error: params["error"]
    )
  end

  def alias_add(conn, params) do
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)

    if can_manage_tag_lists?(current_user) do
      old_tag = params["c_oldtag"] |> to_string() |> String.trim()
      new_tag = params["c_newtag"] |> to_string() |> String.trim()

      case Pages.add_alias(old_tag, new_tag) do
        :ok ->
          redirect(conn, to: "/alias/list?notice=" <> URI.encode_www_form("Alias saved"))

        {:error, :invalid_oldtag} ->
          redirect(conn, to: "/alias/list?error=" <> URI.encode_www_form("Old tag is required"))

        {:error, :invalid_newtag} ->
          redirect(conn, to: "/alias/list?error=" <> URI.encode_www_form("New tag is required"))

        {:error, :same_tag} ->
          redirect(conn,
            to: "/alias/list?error=" <> URI.encode_www_form("Tags cannot be identical")
          )

        _ ->
          redirect(conn, to: "/alias/list?error=" <> URI.encode_www_form("Unable to save alias"))
      end
    else
      send_resp(conn, 403, "Permission Denied")
    end
  end

  def alias_remove(conn, params) do
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)

    if can_manage_tag_lists?(current_user) do
      old_tag = params["d_oldtag"] |> to_string() |> String.trim()

      case Pages.remove_alias(old_tag) do
        :ok ->
          redirect(conn, to: "/alias/list?notice=" <> URI.encode_www_form("Alias removed"))

        _ ->
          redirect(conn, to: "/alias/list?error=" <> URI.encode_www_form("Unable to remove alias"))
      end
    else
      send_resp(conn, 403, "Permission Denied")
    end
  end

  def help_root(conn, _params), do: redirect(conn, to: "/help/#{Help.first_topic()}")

  def help_topic(conn, %{"topic" => topic}) do
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)

    case Help.page(topic, current_user: current_user) do
      {:ok, title, sections} ->
        conn
        |> assign(:page_title, "Help - #{title}")
        |> assign(:has_left_nav, true)
        |> render(:help, topic: topic, title: title, sections: sections)

      :error ->
        send_resp(conn, 404, "Not Found")
    end
  end

  def system(conn, _params) do
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)

    if current_user && admin?(current_user) do
      redirect(conn, to: "/setup")
    else
      target =
        conn.assigns
        |> Map.get(:legacy_chrome, %{})
        |> Map.get(:sub_links, [])
        |> List.first()
        |> case do
          %{href: href} when is_binary(href) and href != "" -> href
          _ -> "/ext_doc"
        end

      redirect(conn, to: target)
    end
  end

  def ext_doc(conn, _params) do
    rows = Pages.extension_manager_rows(include_disabled: false)

    conn
    |> assign(:page_title, "Board Help")
    |> render(:ext_doc, rows: rows, page_kind: :help)
  end

  def ext_manager(conn, _params) do
    with {:ok, user} <- current_user(conn),
         true <- admin?(user) do
      rows = Pages.extension_manager_rows(include_disabled: true)

      conn
      |> assign(:page_title, "Extension Manager")
      |> render(:ext_doc, rows: rows, page_kind: :manager)
    else
      _ ->
        rows = Pages.extension_manager_rows(include_disabled: false)

        conn
        |> assign(:page_title, "Board Help")
        |> render(:ext_doc, rows: rows, page_kind: :help)
    end
  end

  def setup(conn, params) do
    with {:ok, user} <- current_user(conn),
         true <- admin?(user) do
      entries = Pages.list_config_entries(2_000)
      theme_options = Pages.available_themes()
      setup_sections = build_setup_sections(entries, theme_options)

      conn
      |> assign(:page_title, "Board Config")
      |> render(:setup,
        setup_sections: setup_sections,
        notice: params["notice"],
        error: params["error"]
      )
    else
      _ -> send_resp(conn, 403, "Permission Denied")
    end
  end

  def setup_save(conn, params) do
    with {:ok, user} <- current_user(conn),
         true <- admin?(user) do
      results =
        for {"_type_" <> name, type} <- params, reduce: [] do
          acc ->
            value = Map.get(params, "_config_#{name}")
            normalized = cast_setup_value(type, value)
            [{name, Store.put_config(name, normalized)} | acc]
        end

      if Enum.all?(results, fn {_name, result} -> result == :ok end) do
        redirect(conn, to: "/setup?notice=" <> URI.encode_www_form("Config saved"))
      else
        redirect(conn, to: "/setup?error=" <> URI.encode_www_form("Unable to save config"))
      end
    else
      _ -> send_resp(conn, 403, "Permission Denied")
    end
  end

  def nicetest(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end

  def setup_config(conn, params) do
    with {:ok, user} <- current_user(conn),
         true <- admin?(user) do
      selected_name = params["name"] |> to_string() |> String.trim()
      allowed_names = Pages.list_config_entries(2_000) |> Enum.map(& &1.name)
      selected_value = normalize_form_value(params["value"])

      cond do
        selected_name == "" ->
          redirect(conn,
            to: "/setup?error=" <> URI.encode_www_form("Setting name is required")
          )

        selected_name not in allowed_names ->
          redirect(conn,
            to: "/setup?error=" <> URI.encode_www_form("Unknown setting selected")
          )

        Store.put_config(selected_name, selected_value) == :ok ->
          redirect(conn,
            to:
              "/setup?notice=" <>
                URI.encode_www_form("Updated #{selected_name}")
          )

        true ->
          redirect(conn,
            to: "/setup?error=" <> URI.encode_www_form("Unable to save setting")
          )
      end
    else
      _ -> send_resp(conn, 403, "Permission Denied")
    end
  end

  def setup_theme(conn, params) do
    with {:ok, user} <- current_user(conn),
         true <- admin?(user) do
      selected_theme = params["theme"] |> to_string() |> String.trim()
      allowed_themes = Pages.available_themes() |> Enum.map(& &1.value)

      cond do
        selected_theme == "" ->
          redirect(conn,
            to: "/setup?error=" <> URI.encode_www_form("Theme is required")
          )

        selected_theme not in allowed_themes ->
          redirect(conn,
            to: "/setup?error=" <> URI.encode_www_form("Unknown theme selected")
          )

        Store.put_config("theme", selected_theme) == :ok ->
          redirect(conn,
            to: "/setup?notice=" <> URI.encode_www_form("Theme updated")
          )

        true ->
          redirect(conn,
            to: "/setup?error=" <> URI.encode_www_form("Unable to save theme")
          )
      end
    else
      _ -> send_resp(conn, 403, "Permission Denied")
    end
  end

  def admin_tools(conn, _params) do
    with {:ok, user} <- current_user(conn),
         true <- admin?(user) do
      conn
      |> assign(:page_title, "Admin Tools")
      |> render(:admin_tools)
    else
      _ -> send_resp(conn, 403, "Permission Denied")
    end
  end

  def admin_permissions(conn, _params), do: redirect(conn, to: "/permissions")

  def permissions(conn, params) do
    with {:ok, user} <- current_user(conn),
         true <- admin?(user) do
      conn
      |> assign(:page_title, "Permissions Editor")
      |> render(:permissions,
        rows: Permissions.editor_rows(),
        known_classes: Permissions.known_classes(),
        notice: params["notice"],
        error: params["error"]
      )
    else
      _ -> send_resp(conn, 403, "Permission Denied")
    end
  end

  def permissions_save(conn, params) do
    with {:ok, user} <- current_user(conn),
         true <- admin?(user) do
      rule_values = Map.get(params, "rules", %{})

      results =
        for %{id: id} <- Permissions.rules(), reduce: [] do
          acc ->
            value = Map.get(rule_values, id, "")
            [{id, Permissions.set_classes(id, value)} | acc]
        end

      if Enum.all?(results, fn {_id, result} -> result == :ok end) do
        redirect(conn, to: "/permissions?notice=" <> URI.encode_www_form("Permissions saved"))
      else
        redirect(conn, to: "/permissions?error=" <> URI.encode_www_form("Unable to save rules"))
      end
    else
      _ -> send_resp(conn, 403, "Permission Denied")
    end
  end

  def cron_upload(conn, _params) do
    conn
    |> assign(:page_title, "Cron Upload")
    |> render(:cron_upload)
  end

  def blotter_editor(conn, _params) do
    with {:ok, user} <- current_user(conn),
         true <- admin?(user) do
      conn
      |> assign(:page_title, "Blotter Editor")
      |> render(:blotter_editor,
        entries: Pages.list_blotter(),
        notice: conn.params["notice"],
        error: conn.params["error"]
      )
    else
      _ -> send_resp(conn, 403, "Permission Denied")
    end
  end

  def blotter_add(conn, params) do
    with {:ok, user} <- current_user(conn),
         true <- admin?(user) do
      entry_text =
        params["entry_text"]
        |> to_string()
        |> String.trim()

      important? = truthy?(params["important"]) or truthy?(params["c_important"])

      case Pages.add_blotter_entry(entry_text, important?) do
        :ok ->
          redirect(conn, to: "/blotter/editor?notice=" <> URI.encode_www_form("Entry added"))

        {:error, :invalid_entry} ->
          redirect(conn, to: "/blotter/editor?error=" <> URI.encode_www_form("Entry is required"))

        _ ->
          redirect(conn,
            to: "/blotter/editor?error=" <> URI.encode_www_form("Unable to add entry")
          )
      end
    else
      _ -> send_resp(conn, 403, "Permission Denied")
    end
  end

  def system_info(conn, _params) do
    with {:ok, user} <- current_user(conn),
         true <- admin?(user) do
      conn
      |> assign(:page_title, "System Info")
      |> render(:system_info, info: Pages.system_info_data())
    else
      _ -> send_resp(conn, 403, "Permission Denied")
    end
  end

  def ip_ban_list(conn, params) do
    with {:ok, user} <- current_user(conn),
         true <- admin?(user) do
      limit =
        case Integer.parse(to_string(params["r__size"] || "100")) do
          {n, ""} when n > 0 -> min(n, 100_000)
          _ -> 100
        end

      page = parse_page(params["r__page"])
      include_all? = truthy?(params["r_all"])
      page_data = IPBans.list_page(page, limit, include_all: include_all?)
      create_defaults = ip_ban_create_defaults(params, user)
      prev_page = page_data.page - 1
      next_page = page_data.page + 1

      conn
      |> assign(:page_title, "IP Bans")
      |> render(:ip_ban_list,
        bans: page_data.rows,
        page: page_data.page,
        total_pages: page_data.total_pages,
        paginator_items: paginator_items(page_data.page, page_data.total_pages),
        prev_path:
          if(page_data.page > 1,
            do: ip_ban_list_path(prev_page, limit, include_all?),
            else: nil
          ),
        next_path:
          if(page_data.page < page_data.total_pages,
            do: ip_ban_list_path(next_page, limit, include_all?),
            else: nil
          ),
        limit: limit,
        include_all?: include_all?,
        active_path: "/ip_ban/list?r__size=1000000",
        all_path: "/ip_ban/list?r_all=on&r__size=1000000",
        page_path_fn: fn n -> ip_ban_list_path(n, limit, include_all?) end,
        create_defaults: create_defaults,
        notice: params["notice"],
        error: params["error"]
      )
    else
      _ -> send_resp(conn, 403, "Permission Denied")
    end
  end

  def ip_ban_create(conn, params) do
    with {:ok, user} <- current_user(conn),
         true <- admin?(user) do
      case IPBans.create(params, user) do
        {:ok, ip} ->
          redirect(conn, to: ip_ban_feedback_path(params, :notice, "Ban for #{ip} added"))

        {:error, :invalid_ip} ->
          redirect(conn, to: ip_ban_error_path(params, "Invalid IP or CIDR"))

        {:error, :invalid_expiry} ->
          redirect(conn, to: ip_ban_error_path(params, "Invalid expiry value"))

        {:error, :permission_denied} ->
          send_resp(conn, 403, "Permission Denied")

        _ ->
          redirect(conn, to: ip_ban_error_path(params, "Unable to add ban"))
      end
    else
      _ -> send_resp(conn, 403, "Permission Denied")
    end
  end

  def ip_ban_delete(conn, params) do
    with {:ok, user} <- current_user(conn),
         true <- admin?(user) do
      case IPBans.delete(params["d_id"], user) do
        :ok ->
          redirect(conn, to: ip_ban_feedback_path(params, :notice, "Ban removed"))

        {:error, :invalid_id} ->
          redirect(conn, to: ip_ban_feedback_path(params, :error, "Invalid ban ID"))

        {:error, :permission_denied} ->
          send_resp(conn, 403, "Permission Denied")

        _ ->
          redirect(conn, to: ip_ban_feedback_path(params, :error, "Unable to remove ban"))
      end
    else
      _ -> send_resp(conn, 403, "Permission Denied")
    end
  end

  def ip_ban_bulk(conn, params) do
    with {:ok, user} <- current_user(conn),
         true <- admin?(user) do
      action = params["bulk_action"] |> to_string() |> String.trim() |> String.downcase()

      case action do
        "delete" ->
          ids = List.wrap(params["id"])

          case IPBans.delete_many(ids, user) do
            {:ok, count} ->
              redirect(conn, to: ip_ban_feedback_path(params, :notice, "#{count} ban(s) removed"))

            {:error, :permission_denied} ->
              send_resp(conn, 403, "Permission Denied")

            _ ->
              redirect(
                conn,
                to: ip_ban_feedback_path(params, :error, "Unable to remove selected bans")
              )
          end

        _ ->
          redirect(conn, to: ip_ban_feedback_path(params, :error, "Invalid bulk action"))
      end
    else
      _ -> send_resp(conn, 403, "Permission Denied")
    end
  end

  def source_history_all(conn, %{"page_num" => page_num}) do
    with {:ok, user} <- current_user(conn),
         true <- admin?(user) do
      page = parse_page(page_num)
      {entries, has_next?} = Pages.source_history_global(page, 100)

      conn
      |> assign(:page_title, "Global Source History")
      |> render(:source_history,
        heading: "Global Source History",
        entries: entries,
        prev_path: if(page > 1, do: "/source_history/all/#{page - 1}", else: nil),
        next_path: if(has_next?, do: "/source_history/all/#{page + 1}", else: nil)
      )
    else
      _ -> send_resp(conn, 403, "Permission Denied")
    end
  end

  def source_history_image(conn, %{"image_id" => image_id}) do
    with {:ok, user} <- current_user(conn),
         true <- admin?(user),
         {id, ""} when id > 0 <- Integer.parse(to_string(image_id)) do
      conn
      |> assign(:page_title, "Post #{id} Source History")
      |> render(:source_history,
        heading: "Source History: #{id}",
        entries: Pages.source_history_for_image(id, 100),
        prev_path: nil,
        next_path: nil
      )
    else
      :error -> send_resp(conn, 403, "Permission Denied")
      false -> send_resp(conn, 403, "Permission Denied")
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  def tag_history_all(conn, %{"page_num" => page_num}) do
    with {:ok, user} <- current_user(conn),
         true <- admin?(user) do
      page = parse_page(page_num)
      {entries, has_next?} = Pages.tag_history_global(page, 100)

      conn
      |> assign(:page_title, "Global Tag History")
      |> render(:tag_history,
        heading: "Global Tag History",
        entries: entries,
        prev_path: if(page > 1, do: "/tag_history/all/#{page - 1}", else: nil),
        next_path: if(has_next?, do: "/tag_history/all/#{page + 1}", else: nil)
      )
    else
      _ -> send_resp(conn, 403, "Permission Denied")
    end
  end

  def tag_history_image(conn, %{"image_id" => image_id}) do
    with {:ok, user} <- current_user(conn),
         true <- admin?(user),
         {id, ""} when id > 0 <- Integer.parse(to_string(image_id)) do
      conn
      |> assign(:page_title, "Post #{id} Tag History")
      |> render(:tag_history,
        heading: "Tag History: #{id}",
        entries: Pages.tag_history_for_image(id, 100),
        prev_path: nil,
        next_path: nil
      )
    else
      :error -> send_resp(conn, 403, "Permission Denied")
      false -> send_resp(conn, 403, "Permission Denied")
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  def ext_doc_topic(conn, %{"topic" => topic}) do
    case Pages.system_doc(topic) do
      nil ->
        send_resp(conn, 404, "Not Found")

      %{title: title, body_html: body_html} ->
        conn
        |> assign(:page_title, title)
        |> render(:ext_doc_topic, title: title, body_html: body_html)
    end
  end

  def user_admin_root(conn, _params), do: redirect(conn, to: "/user_admin/login")

  def login(conn, params) do
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)

    if current_user do
      redirect(conn, to: "/user")
    else
      conn
      |> assign(:page_title, "#{Pages.site_title()} - Account")
      |> render(:login,
        signup_enabled: Users.signup_enabled?(),
        notice: params["notice"],
        error: params["error"]
      )
    end
  end

  def user(conn, params) do
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)
    requested_name = params["name"] |> maybe_decode_user_name()

    display_user =
      case requested_name do
        nil -> current_user
        name -> Users.get_user_by_name(name)
      end

    cond do
      requested_name == nil and is_nil(current_user) ->
        conn
        |> put_status(401)
        |> assign(:page_title, "#{Pages.site_title()} - Not Logged In")
        |> render(:user_not_logged_in)

      is_nil(display_user) or display_user.id == Users.anonymous_id() ->
        conn
        |> put_status(404)
        |> assign(:page_title, "#{Pages.site_title()} - No Such User")
        |> render(:user_not_found)

      true ->
        can_edit? =
          current_user &&
            (current_user.id == display_user.id or to_string(current_user.class) == "admin")

        can_edit_bio? =
          current_user && current_user.id == display_user.id &&
            display_user.id != Users.anonymous_id()

        can_view_ips? =
          current_user &&
            (current_user.id == display_user.id or admin?(current_user)) &&
            display_user.id != Users.anonymous_id()

        class_options =
          Users.list_users(%{}, 1).classes
          |> Enum.reject(&(&1 in [nil, ""]))

        conn
        |> assign(:page_title, "#{display_user.name}'s Page")
        |> render(:user_show,
          current_user: current_user,
          display_user: display_user,
          notice: params["notice"],
          error: params["error"],
          current_ip: Users.remote_ip_string(conn),
          can_edit?: can_edit?,
          show_admin_ops?: current_user && to_string(current_user.class) == "admin",
          class_options: class_options,
          anonymous_id: Users.anonymous_id(),
          biography: UserProfile.biography(display_user.id),
          can_edit_bio?: can_edit_bio?,
          can_view_ips?: can_view_ips?,
          ip_history: if(can_view_ips?, do: UserProfile.ip_history(display_user), else: nil),
          can_read_pm?: PrivateMessages.can_read?(current_user),
          can_send_pm?:
            PrivateMessages.can_send?(current_user) && current_user &&
              current_user.id != display_user.id,
          private_messages: PrivateMessages.list_for_display(display_user, current_user)
        )
    end
  end

  def user_config(conn, params), do: user(conn, params)

  def biography_save(conn, %{"biography" => biography}) do
    with {:ok, user} <- current_user(conn) do
      case UserProfile.set_biography(user.id, biography) do
        :ok ->
          redirect(conn, to: "/user?notice=" <> URI.encode_www_form("Bio Updated") <> "#about-me")

        _ ->
          redirect(
            conn,
            to: "/user?error=" <> URI.encode_www_form("Unable to update biography") <> "#about-me"
          )
      end
    else
      _ -> send_resp(conn, 403, "Permission Denied")
    end
  end

  def biography_save(conn, _params), do: send_resp(conn, 400, "Bad Request")

  def pm_read(conn, %{"pm_id" => pm_id}) do
    with {:ok, user} <- current_user(conn),
         true <- PrivateMessages.can_read?(user),
         {id, ""} <- Integer.parse(to_string(pm_id)),
         {:ok, pm} <- PrivateMessages.get_visible(id, user) do
      _ = if(pm.to_id == user.id, do: PrivateMessages.mark_read(id), else: :ok)

      conn
      |> assign(:page_title, "Private Message")
      |> render(:pm_read,
        pm: pm,
        from_name: pm.from_name,
        sent_date: String.slice(to_string(pm.sent_date), 0, 16),
        can_reply?: PrivateMessages.can_send?(user)
      )
    else
      :error -> send_resp(conn, 403, "Permission Denied")
      false -> send_resp(conn, 403, "Permission Denied")
      {:error, :permission_denied} -> send_resp(conn, 403, "Permission Denied")
      {:error, :not_found} -> send_resp(conn, 404, "Not Found")
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  def pm_delete(conn, %{"pm_id" => pm_id}) do
    with {:ok, user} <- current_user(conn),
         true <- PrivateMessages.can_read?(user),
         {id, ""} <- Integer.parse(to_string(pm_id)) do
      case PrivateMessages.delete(id, user) do
        :ok ->
          redirect(
            conn,
            to:
              "/user?notice=" <>
                URI.encode_www_form("PM deleted") <> "#private-messages"
          )

        {:error, :permission_denied} ->
          send_resp(conn, 403, "Permission Denied")

        {:error, :not_found} ->
          send_resp(conn, 404, "Not Found")

        _ ->
          redirect(
            conn,
            to:
              "/user?error=" <> URI.encode_www_form("Unable to delete PM") <> "#private-messages"
          )
      end
    else
      :error -> send_resp(conn, 403, "Permission Denied")
      false -> send_resp(conn, 403, "Permission Denied")
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  def pm_send(conn, params) do
    with {:ok, user} <- current_user(conn),
         true <- PrivateMessages.can_send?(user),
         {to_id, ""} <- Integer.parse(to_string(params["to_id"] || "")) do
      subject = to_string(params["subject"] || "")
      message = to_string(params["message"] || "")

      case PrivateMessages.send(
             user,
             to_id,
             subject,
             message,
             Users.remote_ip_string(conn)
           ) do
        :ok ->
          redirect(
            conn,
            to:
              "/user?notice=" <>
                URI.encode_www_form("PM sent") <> "#private-messages"
          )

        {:error, :invalid_recipient} ->
          redirect(
            conn,
            to:
              "/user?error=" <>
                URI.encode_www_form("Invalid recipient") <> "#private-messages"
          )

        {:error, :empty_message} ->
          redirect(
            conn,
            to:
              "/user?error=" <>
                URI.encode_www_form("Message body is required") <> "#private-messages"
          )

        {:error, :permission_denied} ->
          send_resp(conn, 403, "Permission Denied")

        _ ->
          redirect(
            conn,
            to: "/user?error=" <> URI.encode_www_form("Unable to send PM") <> "#private-messages"
          )
      end
    else
      :error -> send_resp(conn, 403, "Permission Denied")
      false -> send_resp(conn, 403, "Permission Denied")
      _ -> send_resp(conn, 400, "Bad Request")
    end
  end

  def login_post(conn, %{"user" => user, "pass" => pass}) do
    case Users.login(user, pass, Users.remote_ip_string(conn)) do
      {:ok, logged_user, session_token} ->
        conn
        |> configure_session(renew: true)
        |> Users.put_user_session(logged_user)
        |> put_auth_cookies(logged_user.name, session_token)
        |> redirect(to: login_redirect_target(conn))

      {:error, :invalid_credentials} ->
        redirect(conn,
          to: "/user_admin/login?error=" <> URI.encode_www_form("Invalid username or password")
        )
    end
  end

  def login_post(conn, _params),
    do:
      redirect(conn, to: "/user_admin/login?error=" <> URI.encode_www_form("Missing credentials"))

  def recover(conn, %{"username" => username}) do
    case Users.recover(username) do
      {:error, :no_email} ->
        redirect(conn,
          to:
            "/user_admin/login?error=" <>
              URI.encode_www_form("That user has no registered email address")
        )

      {:error, :not_implemented} ->
        redirect(conn,
          to:
            "/user_admin/login?error=" <>
              URI.encode_www_form("Email sending is not implemented yet")
        )

      _ ->
        redirect(conn, to: "/user_admin/login?error=" <> URI.encode_www_form("No such user"))
    end
  end

  def recover(conn, _params),
    do: redirect(conn, to: "/user_admin/login?error=" <> URI.encode_www_form("Missing username"))

  def create(conn, params) do
    if Users.signup_enabled?() do
      conn
      |> assign(:page_title, "#{Pages.site_title()} - Create Account")
      |> render(:create,
        notice: params["notice"],
        error: params["error"],
        recaptcha_site_key: Users.recaptcha_site_key()
      )
    else
      conn
      |> assign(:page_title, "#{Pages.site_title()} - Signups Disabled")
      |> render(:signups_disabled)
    end
  end

  def create_post(conn, params) do
    if Users.signup_enabled?() do
      case Users.create_user(params, Users.remote_ip_string(conn), %{login: true}) do
        {:ok, user, session_token} ->
          conn
          |> configure_session(renew: true)
          |> Users.put_user_session(user)
          |> put_auth_cookies(user.name, session_token)
          |> redirect(to: "/post/list")

        {:error, reason} ->
          redirect(conn,
            to: "/user_admin/create?error=" <> URI.encode_www_form(error_message(reason))
          )
      end
    else
      redirect(conn,
        to:
          "/user_admin/create?error=" <>
            URI.encode_www_form("Account creation is currently disabled")
      )
    end
  end

  def create_other(conn, params) do
    actor = Users.current_user(conn)

    if actor && actor.class == "admin" do
      case Users.create_user(params, Users.remote_ip_string(conn), %{login: false}) do
        {:ok, _user, _} ->
          redirect(conn, to: "/user_admin/list?notice=" <> URI.encode_www_form("Created new user"))

        {:error, reason} ->
          redirect(conn,
            to: "/user_admin/list?error=" <> URI.encode_www_form(error_message(reason))
          )
      end
    else
      send_resp(conn, 403, "Permission Denied")
    end
  end

  def user_list(conn, params) do
    with {:ok, user} <- current_user(conn),
         true <- admin?(user) do
      list = Users.list_users(params, 100)
      page_links = user_list_pages(params, list.page, list.total_pages)
      sort_paths = user_list_sort_paths(params)

      conn
      |> assign(:page_title, "#{Pages.site_title()} - User List")
      |> assign(:has_left_nav, true)
      |> render(:user_list,
        users: list.users,
        classes: list.classes,
        email_enabled?: list.email_enabled?,
        filters: list.filters,
        sort: list.sort,
        sort_paths: sort_paths,
        page: list.page,
        total_pages: list.total_pages,
        first_path: if(list.page > 1, do: user_list_path(params, 1), else: nil),
        prev_path: if(list.page > 1, do: user_list_path(params, list.page - 1), else: nil),
        next_path:
          if(list.page < list.total_pages, do: user_list_path(params, list.page + 1), else: nil),
        last_path:
          if(list.page < list.total_pages, do: user_list_path(params, list.total_pages), else: nil),
        page_links: page_links,
        notice: params["notice"],
        error: params["error"]
      )
    else
      _ ->
        send_resp(conn, 403, "Permission Denied")
    end
  end

  def logout(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> delete_resp_cookie("shm_user", path: "/")
    |> delete_resp_cookie("shm_session", path: "/")
    |> delete_resp_cookie("user", path: "/")
    |> delete_resp_cookie("session", path: "/")
    |> redirect(to: "/post/list")
  end

  def change_name(conn, params) do
    actor = Users.current_user(conn)
    params = with_user_id(params)

    case Users.change_name(actor, params) do
      {:ok, user} ->
        conn
        |> maybe_refresh_user_cookie(actor, user.name)
        |> redirect(to: "/user_admin/list?notice=" <> URI.encode_www_form("Username changed"))

      {:error, reason} ->
        redirect(conn, to: "/user_admin/list?error=" <> URI.encode_www_form(error_message(reason)))
    end
  end

  def change_pass(conn, params) do
    actor = Users.current_user(conn)
    params = with_user_id(params)
    params = ensure_target_user_id(params, actor)
    self_change? = self_target?(actor, params)

    case Users.change_pass(actor, params, Users.remote_ip_string(conn)) do
      {:ok, user, token} ->
        conn
        |> maybe_set_post_change_auth(actor, user, token)
        |> redirect(to: redirect_after_password_change(self_change?, :notice, "Password changed"))

      {:error, reason} ->
        redirect(conn,
          to: redirect_after_password_change(self_change?, :error, error_message(reason))
        )
    end
  end

  def change_email(conn, params) do
    actor = Users.current_user(conn)
    params = with_user_id(params)

    case Users.change_email(actor, params) do
      {:ok, _user} ->
        redirect(conn, to: "/user_admin/list?notice=" <> URI.encode_www_form("Email changed"))

      {:error, reason} ->
        redirect(conn, to: "/user_admin/list?error=" <> URI.encode_www_form(error_message(reason)))
    end
  end

  def change_class(conn, params) do
    actor = Users.current_user(conn)
    params = with_user_id(params)

    case Users.change_class(actor, params) do
      {:ok, _user} ->
        redirect(conn, to: "/user_admin/list?notice=" <> URI.encode_www_form("Class changed"))

      {:error, reason} ->
        redirect(conn, to: "/user_admin/list?error=" <> URI.encode_www_form(error_message(reason)))
    end
  end

  def delete_user(conn, params) do
    actor = Users.current_user(conn)
    params = with_user_id(params)

    case Users.delete_user(actor, params) do
      {:ok, :deleted} ->
        redirect(conn, to: "/user_admin/list?notice=" <> URI.encode_www_form("User deleted"))

      {:error, reason} ->
        redirect(conn, to: "/user_admin/list?error=" <> URI.encode_www_form(error_message(reason)))
    end
  end

  def wiki_root(conn, _params), do: redirect(conn, to: "/wiki/Index")

  def wiki_show(conn, %{"title" => title}) do
    decoded_title = URI.decode(title)
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)
    requested_revision = parse_positive_int(conn.params["revision"])

    page_result =
      if requested_revision > 0 do
        Pages.wiki_revision(decoded_title, requested_revision)
      else
        Pages.wiki_latest(decoded_title)
      end

    case page_result do
      {:ok, page} ->
        conn
        |> assign(:page_title, "Wiki: #{page.title}")
        |> render(:wiki,
          page: page,
          notice: conn.params["notice"],
          error: conn.params["error"],
          can_edit?: not is_nil(current_user),
          can_admin?: admin?(current_user)
        )

      :not_found ->
        conn
        |> put_status(404)
        |> assign(:page_title, "Wiki: #{decoded_title}")
        |> render(:wiki_missing,
          title: decoded_title,
          can_edit?: not is_nil(current_user),
          notice: conn.params["notice"],
          error: conn.params["error"]
        )

      {:error, :revision_not_found} ->
        conn
        |> put_status(404)
        |> assign(:page_title, "Wiki: #{decoded_title}")
        |> render(:wiki_missing,
          title: decoded_title,
          can_edit?: not is_nil(current_user),
          notice: nil,
          error: "Revision not found"
        )
    end
  end

  def wiki_action(conn, %{"title" => title, "action" => "history"}) do
    decoded_title = URI.decode(title)
    history = Pages.wiki_history(decoded_title)
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)

    conn
    |> assign(:page_title, "Wiki History: #{decoded_title}")
    |> render(:wiki_history,
      title: decoded_title,
      history: history,
      can_revert?: admin?(current_user),
      notice: conn.params["notice"],
      error: conn.params["error"]
    )
  end

  def wiki_action(conn, %{"title" => title, "action" => "edit"}) do
    decoded_title = URI.decode(title)
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)

    if is_nil(current_user) do
      conn
      |> put_status(401)
      |> assign(:page_title, "#{Pages.site_title()} - Not Logged In")
      |> render(:user_not_logged_in)
    else
      body =
        case Pages.wiki_latest(decoded_title) do
          {:ok, page} -> to_string(page.body || "")
          _ -> ""
        end

      conn
      |> assign(:page_title, "Edit Wiki: #{decoded_title}")
      |> render(:wiki_edit,
        title: decoded_title,
        body: body,
        notice: conn.params["notice"],
        error: conn.params["error"]
      )
    end
  end

  def wiki_action(conn, %{"title" => title, "action" => "delete"}) do
    decoded_title = URI.decode(title)
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)

    if admin?(current_user) do
      conn
      |> assign(:page_title, "Delete Wiki: #{decoded_title}")
      |> render(:wiki_delete,
        title: decoded_title,
        notice: conn.params["notice"],
        error: conn.params["error"]
      )
    else
      send_resp(conn, 403, "Permission Denied")
    end
  end

  def wiki_action(conn, %{"title" => title, "action" => "revert"}) do
    decoded_title = URI.decode(title)
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)

    if admin?(current_user) do
      history = Pages.wiki_history(decoded_title)
      selected_revision = parse_positive_int(conn.params["revision"])

      conn
      |> assign(:page_title, "Revert Wiki: #{decoded_title}")
      |> render(:wiki_revert,
        title: decoded_title,
        history: history,
        selected_revision: selected_revision,
        notice: conn.params["notice"],
        error: conn.params["error"]
      )
    else
      send_resp(conn, 403, "Permission Denied")
    end
  end

  def wiki_action(conn, _params) do
    send_resp(conn, 404, "Not Found")
  end

  def wiki_action_post(conn, %{"title" => title, "action" => "edit"} = params) do
    decoded_title = URI.decode(title)
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)

    if is_nil(current_user) do
      send_resp(conn, 403, "Permission Denied")
    else
      body = params["body"] |> to_string()

      case Pages.wiki_save(
             decoded_title,
             body,
             current_user.id,
             Users.remote_ip_string(conn)
           ) do
        :ok ->
          redirect(
            conn,
            to: "/wiki/#{URI.encode(decoded_title)}?notice=" <> URI.encode_www_form("Page saved")
          )

        {:error, :invalid_title} ->
          redirect(
            conn,
            to:
              "/wiki/#{URI.encode(decoded_title)}/edit?error=" <>
                URI.encode_www_form("Invalid wiki title")
          )

        {:error, :empty_body} ->
          redirect(
            conn,
            to:
              "/wiki/#{URI.encode(decoded_title)}/edit?error=" <>
                URI.encode_www_form("Body cannot be empty")
          )

        _ ->
          redirect(
            conn,
            to:
              "/wiki/#{URI.encode(decoded_title)}/edit?error=" <>
                URI.encode_www_form("Unable to save wiki page")
          )
      end
    end
  end

  def wiki_action_post(conn, %{"title" => title, "action" => "delete"}) do
    decoded_title = URI.decode(title)
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)

    if admin?(current_user) do
      case Pages.wiki_delete(decoded_title) do
        :ok ->
          redirect(
            conn,
            to:
              "/wiki/#{URI.encode(decoded_title)}?notice=" <> URI.encode_www_form("Page deleted")
          )

        _ ->
          redirect(
            conn,
            to:
              "/wiki/#{URI.encode(decoded_title)}/delete?error=" <>
                URI.encode_www_form("Unable to delete wiki page")
          )
      end
    else
      send_resp(conn, 403, "Permission Denied")
    end
  end

  def wiki_action_post(conn, %{"title" => title, "action" => "revert"} = params) do
    decoded_title = URI.decode(title)
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)

    if admin?(current_user) do
      revision =
        case Integer.parse(to_string(params["revision"] || "")) do
          {n, ""} when n > 0 -> n
          _ -> 0
        end

      case Pages.wiki_revert(
             decoded_title,
             revision,
             current_user.id,
             Users.remote_ip_string(conn)
           ) do
        :ok ->
          redirect(
            conn,
            to:
              "/wiki/#{URI.encode(decoded_title)}?notice=" <>
                URI.encode_www_form("Page reverted to revision #{revision}")
          )

        {:error, :revision_not_found} ->
          redirect(
            conn,
            to:
              "/wiki/#{URI.encode(decoded_title)}/revert?error=" <>
                URI.encode_www_form("Revision not found")
          )

        _ ->
          redirect(
            conn,
            to:
              "/wiki/#{URI.encode(decoded_title)}/revert?error=" <>
                URI.encode_www_form("Unable to revert wiki page")
          )
      end
    else
      send_resp(conn, 403, "Permission Denied")
    end
  end

  def wiki_action_post(conn, _params) do
    send_resp(conn, 404, "Not Found")
  end

  def blotter_list(conn, _params) do
    entries =
      Pages.list_blotter()
      |> Enum.map(fn [id, entry_date, entry_text, important] ->
        %{
          id: id,
          entry_date: format_blotter_list_date(entry_date),
          entry_text: to_string(entry_text || ""),
          important: important in ["Y", "y", "1", 1, true, "true", "TRUE"]
        }
      end)

    blotter_color = normalize_blotter_color(Store.get_config("blotter_color", "FF0000"))

    conn
    |> assign(:page_title, "Blotter")
    |> render(:blotter, entries: entries, blotter_color: blotter_color)
  end

  def random(conn, params) do
    if is_binary(params["search"]) and params["search"] != "" and
         not Map.has_key?(params, "path_search") do
      redirect(conn, to: "/random/#{URI.encode(params["search"])}")
    else
      search = decode_search(params["path_search"])

      random_count =
        case Integer.parse(to_string(Store.get_config("random_images_list_count", "12") || "12")) do
          {n, ""} when n > 0 -> min(n, 200)
          _ -> 12
        end

      posts =
        Pages.random_posts(search, random_count)
        |> Enum.map(&decorate_random_post/1)

      conn
      |> assign(:page_title, "Random Posts")
      |> assign(:has_left_nav, true)
      |> render(:random_list, search: search, posts: posts)
    end
  end

  def random_image(conn, %{"action" => action} = params) do
    search = decode_search(params["search"])

    case action do
      "view" -> random_redirect(conn, search)
      "download" -> random_redirect(conn, search)
      "widget" -> random_widget(conn, search)
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  def sitemap_xml(conn, _params) do
    full? = truthy?(Store.get_config("sitemap_generatefull", "0"))
    max_entries = if(full?, do: 50_000, else: 50)
    page_size = min(max_entries, 500)
    posts = collect_sitemap_posts(page_size, max_entries, [])
    base = site_base_url(conn)

    body =
      [
        ~S(<?xml version="1.0" encoding="UTF-8"?>),
        ~S(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">),
        sitemap_url_xml(base <> "/"),
        sitemap_url_xml(base <> "/post/list")
      ] ++
        Enum.map(posts, fn post ->
          sitemap_url_xml(base <> "/post/view/#{post.id}", to_string(post.posted || ""))
        end) ++
        [~S(</urlset>)]

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, Enum.join(body, "\n"))
  end

  def danbooru_find_posts(conn, params) do
    payload = params |> danbooru_posts(conn) |> Enum.map(&danbooru_post_payload/1)
    json(conn, payload)
  end

  def danbooru_find_posts_xml(conn, params) do
    posts = params |> danbooru_posts(conn) |> Enum.map(&danbooru_post_payload/1)
    page = parse_page(params["page"])
    limit = params["limit"] |> parse_page() |> min(200) |> max(1)
    offset = max(page - 1, 0) * limit

    lines =
      [
        ~S(<?xml version="1.0" encoding="UTF-8"?>),
        ~s(<posts count="#{length(posts)}" offset="#{offset}">)
      ] ++
        Enum.map(posts, fn post ->
          attrs =
            [
              {"id", post.id},
              {"md5", post.md5},
              {"file_name", post.file_name},
              {"file_url", post.file_url},
              {"height", post.height},
              {"width", post.width},
              {"preview_url", post.preview_url},
              {"preview_height", post.preview_height},
              {"preview_width", post.preview_width},
              {"rating", post.rating},
              {"date", post.date},
              {"is_warehoused", "false"},
              {"tags", post.tags},
              {"source", post.source},
              {"score", 0},
              {"author", post.author}
            ]
            |> Enum.map(fn {key, value} ->
              ~s(#{key}="#{xml_escape(value)}")
            end)
            |> Enum.join(" ")

          "<post #{attrs} />"
        end) ++
        ["</posts>"]

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, Enum.join(lines, "\n"))
  end

  defp upload_entries(params) do
    file_entries =
      params
      |> Enum.flat_map(fn
      {"data" <> row, uploads} when is_list(uploads) ->
        parsed_row = parse_row_number(row)

        uploads
        |> Enum.with_index()
        |> Enum.flat_map(fn
          {%Plug.Upload{} = upload, order} ->
            [%{kind: :file, row: parsed_row, order: order, upload: upload}]

          _ -> []
        end)

      {"data" <> row, %Plug.Upload{} = upload} ->
        [%{kind: :file, row: parse_row_number(row), order: 0, upload: upload}]

      _ ->
        []
    end)

    url_entries =
      params
      |> Enum.flat_map(fn
        {"url" <> row, value} ->
          url = value |> to_string() |> String.trim()

          if url == "" do
            []
          else
            [%{kind: :url, row: parse_row_number(row), order: 10_000, url: url}]
          end

        _ ->
          []
      end)

    (file_entries ++ url_entries)
    |> Enum.sort_by(fn %{row: row, order: order} -> {row, order} end)
  end

  defp parse_row_number(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp anonymous_actor do
    %{id: Users.anonymous_id(), class: "anonymous"}
  end

  defp upload_error_message(:duplicate), do: "Duplicate file skipped"
  defp upload_error_message(:too_large), do: "One or more files exceed upload_size"

  defp upload_error_message(:empty_upload),
    do: "One or more uploads were empty or blocked by request size limits"

  defp upload_error_message(:unsupported_type),
    do: "One or more files use a blocked or unsupported file type"

  defp upload_error_message(:invalid_upload), do: "Invalid upload payload"
  defp upload_error_message(:invalid_url), do: "One or more URL uploads were invalid"
  defp upload_error_message(:transload_disabled), do: "URL uploads are disabled in board settings"
  defp upload_error_message(:transload_failed), do: "One or more URL uploads could not be fetched"
  defp upload_error_message(:db_failed), do: "Database insert failed"
  defp upload_error_message(_), do: "Upload failed"

  defp random_widget(conn, search) do
    case Pages.random_post(search) do
      nil ->
        send_resp(conn, 404, "No random posts found")

      post ->
        thumb = Posts.thumb_route(post)
        href = "/post/view/#{post.id}"

        html =
          ~s(<a href="#{href}" class="thumb shm-thumb shm-thumb-link "><img src="#{thumb}" alt="random" /></a>)

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, html)
    end
  end

  def browser_search_xml(conn, _params) do
    title = Pages.site_title()
    search_form = "/post/list"
    suggest_url = "/browser_search/{searchTerms}"

    xml = """
    <SearchPlugin xmlns='http://www.mozilla.org/2006/browser/search/' xmlns:os='http://a9.com/-/spec/opensearch/1.1/'>
      <os:ShortName>#{title}</os:ShortName>
      <os:InputEncoding>UTF-8</os:InputEncoding>
      <SearchForm>#{search_form}</SearchForm>
      <os:Url type='text/html' method='GET' template='#{search_form}'>
        <os:Param name='search' value='{searchTerms}'/>
      </os:Url>
      <Url type='application/x-suggestions+json' template='#{suggest_url}'/>
    </SearchPlugin>
    """

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, xml)
  end

  def browser_search_suggest(conn, %{"tag_search" => tag_search}) do
    tags = Pages.browser_search_suggestions(tag_search)
    json(conn, [tag_search, tags, [], []])
  end

  def autocomplete(conn, params) do
    search = to_string(params["s"] || "")
    limit = parse_page(params["limit"] || "100")
    json(conn, Pages.autocomplete(search, limit))
  end

  defp random_redirect(conn, search) do
    case Pages.random_post(search) do
      nil ->
        redirect(conn, to: "/post/list")

      %{id: id} ->
        redirect(conn, to: "/post/view/#{id}")
    end
  end

  defp decorate_random_post(post) do
    tags = Map.get(post, :tags, [])
    {thumb_width, thumb_height} = random_thumb_size(post.width, post.height)

    post
    |> Map.put(:data_tags, String.downcase(Enum.join(tags, " ")))
    |> Map.put(:mime, MIME.from_path("file.#{post.ext}") || "application/octet-stream")
    |> Map.put(:thumb_width, thumb_width)
    |> Map.put(:thumb_height, thumb_height)
    |> Map.put(:tooltip, random_tooltip_text(tags, post.width, post.height, post.filesize))
  end

  defp random_thumb_size(width, height) do
    thumb_width = config_int("thumb_width", 192)
    thumb_height = config_int("thumb_height", 192)
    w = if width > 0, do: width, else: 192
    h = if height > 0, do: height, else: 192
    w = if w > h * 5, do: h * 5, else: w
    h = if h > w * 5, do: w * 5, else: h
    scale = min(thumb_width / w, thumb_height / h)

    {max(1, trunc(w * scale)), max(1, trunc(h * scale))}
  end

  defp random_tooltip_text(tags, width, height, filesize) do
    tag_text =
      case tags do
        [] -> "(no tags)"
        _ -> Enum.join(tags, " ")
      end

    "#{tag_text} // #{width}x#{height} // #{human_filesize(filesize)}"
  end

  defp config_int(name, default) do
    case Store.get_config(name, Integer.to_string(default)) |> to_string() |> Integer.parse() do
      {value, ""} when value > 0 -> value
      _ -> default
    end
  end

  defp decode_search(nil), do: ""
  defp decode_search(value), do: value |> to_string() |> URI.decode() |> String.trim()

  defp current_user(conn) do
    case conn.assigns[:legacy_user] || Users.current_user(conn) do
      nil -> :error
      user -> {:ok, user}
    end
  end

  defp format_blotter_list_date(entry_date) do
    value = to_string(entry_date || "")

    case Regex.run(~r/^(\d{4})-(\d{2})-(\d{2})/, value) do
      [_, year, month, day] -> String.slice(year, 2, 2) <> "/" <> month <> "/" <> day
      _ -> value
    end
  end

  defp normalize_blotter_color(value) do
    cleaned =
      value
      |> to_string()
      |> String.trim()
      |> String.trim_leading("#")

    if cleaned == "", do: "FF0000", else: cleaned
  end

  defp can_manage_tag_lists?(user), do: TagEdit.can_edit_tags?(user)

  defp admin?(%{class: class}) do
    class
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> Kernel.==("admin")
  end

  defp admin?(_), do: false

  defp ip_ban_create_defaults(params, user) do
    %{
      ip: params["c_ip"] |> to_string() |> String.trim(),
      mode:
        params["c_mode"]
        |> to_string()
        |> String.trim()
        |> case do
          "" -> "block"
          mode -> mode
        end,
      reason: params["c_reason"] |> to_string() |> String.trim(),
      expires:
        params["c_expires"]
        |> to_string()
        |> String.trim()
        |> case do
          "" -> "+1 week"
          value -> value
        end,
      banner: user.name,
      added: Date.utc_today() |> Date.to_string()
    }
  end

  defp ip_ban_error_path(params, message) do
    keep =
      %{
        "c_ip" => params["c_ip"],
        "c_mode" => params["c_mode"],
        "c_reason" => params["c_reason"],
        "c_expires" => params["c_expires"],
        "r__size" => params["r__size"],
        "r__page" => params["r__page"],
        "r_all" => params["r_all"]
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) or to_string(v) == "" end)
      |> Enum.into(%{})

    query =
      Map.merge(keep, %{"error" => message})
      |> URI.encode_query()

    "/ip_ban/list?" <> query <> "#create"
  end

  defp ip_ban_feedback_path(params, type, message) when type in [:notice, :error] do
    keep =
      %{
        "r__size" => params["r__size"],
        "r__page" => params["r__page"],
        "r_all" => params["r_all"]
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) or to_string(v) == "" end)
      |> Enum.into(%{})

    query =
      keep
      |> Map.put(to_string(type), message)
      |> URI.encode_query()

    "/ip_ban/list?" <> query
  end

  defp ip_ban_list_path(page, limit, include_all?) do
    query =
      %{
        "r__size" => Integer.to_string(max(limit, 1)),
        "r__page" => Integer.to_string(max(page, 1))
      }
      |> maybe_put_r_all(include_all?)
      |> URI.encode_query()

    "/ip_ban/list?" <> query
  end

  defp maybe_put_r_all(params, true), do: Map.put(params, "r_all", "on")
  defp maybe_put_r_all(params, _), do: params

  defp truthy?(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in ["1", "y", "yes", "true", "on", "t"]))
  end

  defp parse_positive_int(value) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} when n > 0 -> n
      _ -> 0
    end
  end

  defp collect_sitemap_posts(page_size, max_entries, acc) do
    do_collect_sitemap_posts(1, page_size, max_entries, acc)
  end

  defp do_collect_sitemap_posts(_page, _page_size, remaining, acc) when remaining <= 0 do
    Enum.reverse(acc)
  end

  defp do_collect_sitemap_posts(page, page_size, remaining, acc) do
    fetch_size = min(page_size, remaining)
    {posts, _count} = Index.list_posts("", page, fetch_size, current_user: nil)

    case posts do
      [] ->
        Enum.reverse(acc)

      rows ->
        do_collect_sitemap_posts(
          page + 1,
          page_size,
          remaining - length(rows),
          Enum.reverse(rows) ++ acc
        )
    end
  end

  defp site_base_url(conn) do
    default_port = if conn.scheme == :https, do: 443, else: 80

    if conn.port == default_port do
      "#{conn.scheme}://#{conn.host}"
    else
      "#{conn.scheme}://#{conn.host}:#{conn.port}"
    end
  end

  defp sitemap_url_xml(url), do: sitemap_url_xml(url, nil)

  defp sitemap_url_xml(url, lastmod) do
    lastmod_value = sitemap_lastmod(lastmod)

    if lastmod_value == nil do
      "<url><loc>#{xml_escape(url)}</loc></url>"
    else
      "<url><loc>#{xml_escape(url)}</loc><lastmod>#{xml_escape(lastmod_value)}</lastmod></url>"
    end
  end

  defp sitemap_lastmod(nil), do: nil
  defp sitemap_lastmod(""), do: nil

  defp sitemap_lastmod(value) do
    text = to_string(value)

    cond do
      text == "" ->
        nil

      match?({:ok, _}, Date.from_iso8601(text)) ->
        text

      true ->
        case NaiveDateTime.from_iso8601(text) do
          {:ok, dt} -> dt |> NaiveDateTime.to_date() |> Date.to_iso8601()
          _ -> String.slice(text, 0, 10)
        end
    end
  end

  defp xml_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp danbooru_posts(params, conn) do
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)
    ids = parse_csv_ints(params["id"])
    md5s = parse_csv_md5s(params["md5"])

    cond do
      ids != [] ->
        ids
        |> Enum.map(&Posts.get_post/1)
        |> Enum.reject(&is_nil/1)

      md5s != [] ->
        posts_by_md5(md5s)

      true ->
        search = params["tags"] |> to_string() |> String.trim()
        limit = params["limit"] |> parse_page() |> min(200) |> max(1)
        page = params["page"] |> parse_page()
        {posts, _count} = Index.list_posts(search, page, limit, current_user: current_user)
        posts
    end
  end

  defp danbooru_post_payload(post) do
    source = post.source || ""
    owner_name = Posts.owner_name(post.id)
    extra = Posts.post_extra(post.id)
    rating = Map.get(extra, :rating, "?")
    file_url = Posts.image_route(post)
    thumb_url = Posts.thumb_route(post)
    width = parse_positive_int(post.width)
    height = parse_positive_int(post.height)
    {preview_width, preview_height} = random_thumb_size(width, height)

    %{
      id: post.id,
      creator: owner_name,
      author: owner_name,
      tags: Enum.join(post.tags || [], " "),
      source: source,
      created_at: to_string(post.posted || ""),
      date: to_string(post.posted || ""),
      rating: rating,
      width: width,
      height: height,
      md5: post.hash,
      file_name: post.filename || "#{post.id}.#{post.ext}",
      file_url: file_url,
      preview_url: thumb_url,
      sample_url: file_url,
      sample_width: width,
      sample_height: height,
      preview_width: preview_width,
      preview_height: preview_height
    }
  end

  defp posts_by_md5(md5s) do
    case sqlite_path() do
      nil -> posts_by_md5_repo(md5s)
      path -> posts_by_md5_sqlite(path, md5s)
    end
  end

  defp posts_by_md5_repo(md5s) do
    md5s
    |> Enum.flat_map(fn md5 ->
      case Repo.query(
             "SELECT id FROM images WHERE LOWER(hash) = LOWER($1) ORDER BY id DESC LIMIT 1",
             [
               md5
             ]
           ) do
        {:ok, %{rows: [[id]]}} ->
          case Posts.get_post(parse_positive_int(id)) do
            nil -> []
            post -> [post]
          end

        _ ->
          []
      end
    end)
  end

  defp posts_by_md5_sqlite(path, md5s) do
    md5s
    |> Enum.flat_map(fn md5 ->
      sql =
        "SELECT id FROM images WHERE LOWER(hash) = LOWER('#{sqlite_escape(md5)}') ORDER BY id DESC LIMIT 1"

      case System.cmd("sqlite3", ["-noheader", path, sql], stderr_to_stdout: true) do
        {output, 0} ->
          case Integer.parse(output |> String.trim()) do
            {id, ""} when id > 0 ->
              case Posts.get_post(id) do
                nil -> []
                post -> [post]
              end

            _ ->
              []
          end

        _ ->
          []
      end
    end)
  end

  defp sqlite_path do
    case Site.sqlite_db_path() do
      path when is_binary(path) and path != "" ->
        if File.exists?(path), do: path, else: nil

      _ ->
        nil
    end
  end

  defp sqlite_escape(value), do: value |> to_string() |> String.replace("'", "''")

  defp parse_csv_ints(value) do
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&parse_positive_int/1)
    |> Enum.reject(&(&1 <= 0))
    |> Enum.uniq()
  end

  defp parse_csv_md5s(value) do
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.filter(&String.match?(&1, ~r/\A[0-9a-f]{32}\z/))
    |> Enum.uniq()
  end

  defp parse_page(value) do
    case Integer.parse(to_string(value || "")) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end

  defp paginator_items(_page, total_pages) when total_pages <= 0, do: []

  defp paginator_items(page, total_pages) do
    pages =
      MapSet.new([1, total_pages] ++ Enum.to_list(max(page - 2, 1)..min(page + 2, total_pages)))
      |> MapSet.to_list()
      |> Enum.sort()

    pages
    |> Enum.reduce({[], nil}, fn n, {acc, prev} ->
      cond do
        is_nil(prev) ->
          {[{:page, n} | acc], n}

        n == prev + 1 ->
          {[{:page, n} | acc], n}

        true ->
          {[{:page, n}, :ellipsis | acc], n}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp login_redirect_target(conn) do
    case Users.login_redirect_mode() do
      "profile" ->
        "/post/list"

      _ ->
        referer = List.first(get_req_header(conn, "referer")) || ""

        cond do
          referer == "" -> "/post/list"
          String.contains?(referer, "/user/") -> "/post/list"
          String.contains?(referer, "/user_admin/") -> "/post/list"
          true -> referer_path(referer)
        end
    end
  end

  defp referer_path(referer) do
    case URI.parse(referer) do
      %URI{path: nil} ->
        "/post/list"

      %URI{path: path, query: nil} when is_binary(path) and path != "" ->
        path

      %URI{path: path, query: query} when is_binary(path) and path != "" ->
        path <> "?" <> query

      _ ->
        "/post/list"
    end
  end

  defp put_auth_cookies(conn, user_name, session_token) do
    max_age = Users.login_memory_days() * 86_400
    cookie_opts = cookie_options(conn, max_age)

    conn
    |> put_resp_cookie("shm_user", user_name, cookie_opts)
    |> put_resp_cookie("shm_session", session_token, cookie_opts)
    |> put_resp_cookie("user", user_name, cookie_opts)
    |> put_resp_cookie("session", session_token, cookie_opts)
  end

  defp maybe_set_post_change_auth(conn, actor, user, token) do
    if actor && actor.id == user.id do
      conn
      |> Users.put_user_session(user)
      |> put_auth_cookies(user.name, token)
    else
      conn
    end
  end

  defp maybe_refresh_user_cookie(conn, actor, updated_name) do
    if actor && actor.name != updated_name &&
         actor.id == Users.session_user_id(conn) do
      conn
      |> Users.put_user_name_session(updated_name)
      |> put_resp_cookie(
        "shm_user",
        updated_name,
        cookie_options(conn, Users.login_memory_days() * 86_400)
      )
      |> put_resp_cookie(
        "user",
        updated_name,
        cookie_options(conn, Users.login_memory_days() * 86_400)
      )
    else
      conn
    end
  end

  defp cookie_options(conn, max_age) do
    [
      path: "/",
      max_age: max_age,
      http_only: true,
      same_site: "Lax",
      secure: conn.scheme == :https
    ]
  end

  defp user_list_pages(_params, _page, total_pages) when total_pages <= 0, do: []

  defp user_list_pages(params, page, total_pages) do
    first = max(page - 4, 1)
    last = min(first + 9, total_pages)

    Enum.map(first..last, fn value ->
      %{page: value, current?: value == page, path: user_list_path(params, value)}
    end)
  end

  defp user_list_path(params, page) do
    base =
      params
      |> Map.take([
        "r_id",
        "r_name",
        "r_email",
        "r_class",
        "r__sort",
        "r__size",
        "error",
        "notice"
      ])
      |> Map.put("r__page", Integer.to_string(page))
      |> Map.put("q", "user_admin/list")
      |> maybe_put_joindate(params["r_joindate"])

    query = Plug.Conn.Query.encode(base)
    "/user_admin/list?" <> query
  end

  defp maybe_put_joindate(map, dates) when is_list(dates), do: Map.put(map, "r_joindate", dates)
  defp maybe_put_joindate(map, _), do: map

  defp user_list_sort_paths(params) do
    %{
      id: user_list_sort_path(params, "id"),
      name: user_list_sort_path(params, "name"),
      email: user_list_sort_path(params, "email"),
      class: user_list_sort_path(params, "class"),
      joindate: user_list_sort_path(params, "joindate")
    }
  end

  defp user_list_sort_path(params, sort) do
    params
    |> Map.put("r__sort", sort)
    |> user_list_path(1)
  end

  defp build_setup_sections(entries, theme_options) do
    entries_map = Map.new(entries, fn entry -> {entry.name, entry.value} end)
    counter_options = home_counter_options()

    specs = [
      {"General",
       [
         %{name: "title", label: "Site title: ", type: "string"},
         %{name: "front_page", label: "Front page: ", type: "string", leading_break?: true},
         %{name: "main_page", label: "Main page: ", type: "string", leading_break?: true},
         %{name: "contact_link", label: "Contact URL: ", type: "string", leading_break?: true},
         %{
           name: "theme",
           label: "Theme: ",
           type: "string",
           leading_break?: true,
           input: :select,
           options: theme_options
         },
         %{
           name: "nice_urls",
           label: "Nice URLs: ",
           type: "bool",
           leading_break?: true,
           input: :bool
         },
         %{kind: :nicetest}
       ]},
      {"Upload",
       [
         %{name: "upload_count", label: "Max uploads: ", type: "int", input: :number},
         %{name: "upload_size", label: "Max size per file: ", type: "int", leading_break?: true},
         %{
           name: "upload_anon",
           label: "Allow anonymous uploads: ",
           type: "bool",
           leading_break?: true,
           input: :bool
         },
         %{
           name: "transload_engine",
           label: "Transload: ",
           type: "string",
           leading_break?: true,
           input: :select,
           options: [
             %{label: "Disabled", value: "none"},
             %{label: "cURL", value: "curl"},
             %{label: "fopen", value: "fopen"},
             %{label: "WGet", value: "wget"}
           ]
         },
         %{
           name: "upload_tlsource",
           label: "Use transloaded URL as source if none is provided: ",
           type: "bool",
           leading_break?: true,
           input: :bool
         }
       ]},
      {"Index Options",
       [
         %{
           name: "index_images",
           label: "images on the post list",
           type: "int",
           input: :inline_number
         }
       ]},
      {"Post Options",
       [
         %{name: "image_tip", label: "Post tooltip", type: "string"},
         %{name: "image_info", label: "Post info", type: "string"},
         %{
           name: "upload_collision_handler",
           label: "Upload collision handler",
           type: "string",
           input: :select,
           options: [%{label: "Error", value: "error"}, %{label: "Merge", value: "merge"}]
         },
         %{
           name: "image_on_delete",
           label: "On Delete",
           type: "string",
           input: :select,
           options: [
             %{label: "Return to post list", value: "list"},
             %{label: "Go to next post", value: "next"}
           ]
         },
         %{name: "image_show_meta", label: "Show metadata", type: "bool", input: :bool_compact}
       ], :table},
      {"Comment Options",
       [
         %{
           name: "comment_captcha",
           label: "Require CAPTCHA for anonymous comments: ",
           type: "bool",
           input: :bool
         },
         %{kind: :label, html: "<br>Limit to "},
         %{name: "comment_limit", type: "int", input: :number},
         %{kind: :label, html: " comments per "},
         %{name: "comment_window", type: "int", input: :number},
         %{kind: :label, html: " minutes"},
         %{kind: :label, html: "<br>Show "},
         %{name: "comment_count", type: "int", input: :number},
         %{kind: :label, html: " recent comments on the index"},
         %{kind: :label, html: "<br>Show "},
         %{name: "comment_list_count", type: "int", input: :number},
         %{kind: :label, html: " comments per image on the list"},
         %{kind: :label, html: "<br>Make samefags public "},
         %{name: "comment_samefags_public", type: "bool", input: :bool}
       ]},
      {"Thumbnailing",
       [
         %{
           name: "thumb_engine",
           label: "Engine",
           type: "string",
           input: :select,
           options: [
             %{label: "Built-in GD", value: "gd"},
             %{label: "ImageMagick", value: "imagick"},
             %{label: "Convert", value: "convert"}
           ]
         },
         %{
           name: "thumb_mime",
           label: "Filetype",
           type: "string",
           input: :select,
           options: [
             %{label: "JPEG", value: "image/jpeg"},
             %{label: "WEBP", value: "image/webp"}
           ]
         },
         %{name: "thumb_width", label: "Max Width", type: "int", input: :number},
         %{name: "thumb_height", label: "Max Height", type: "int", input: :number},
         %{
           name: "thumb_fit",
           label: "Fit",
           type: "string",
           input: :select,
           options: [
             %{label: "Fit", value: "Fit"},
             %{label: "Fit Blur", value: "Fit Blur"},
             %{label: "Fit Blur Tall, Fill Wide", value: "Fit Blur Tall, Fill Wide"},
             %{label: "Fill", value: "Fill"},
             %{label: "Stretch", value: "Stretch"}
           ]
         },
         %{name: "thumb_quality", label: "Quality", type: "int", input: :number},
         %{name: "thumb_scaling", label: "High-DPI Scale %", type: "int", input: :number},
         %{name: "thumb_alpha_color", label: "Alpha Conversion Color", type: "string"}
       ], :table},
      {"User Options",
       [
         %{
           name: "ext_user_config_enable_api_keys",
           label: "Enable user API keys",
           type: "bool",
           input: :bool
         },
         %{
           name: "login_signup_enabled",
           label: "Allow new signups",
           type: "bool",
           input: :bool,
           leading_break?: true
         },
         %{
           name: "login_tac",
           label: "Terms & Conditions",
           type: "string",
           input: :textarea,
           leading_break?: true,
           rows: 6
         },
         %{
           name: "user_loginshowprofile",
           label: "On log in/out: ",
           type: "string",
           input: :select,
           leading_break?: true,
           options: [
             %{label: "return to previous page", value: "0"},
             %{label: "send to user profile", value: "1"}
           ]
         },
         %{
           name: "avatar_host",
           label: "Avatars: ",
           type: "string",
           input: :select,
           leading_break?: true,
           options: [
             %{label: "None", value: "none"},
             %{label: "Gravatar", value: "gravatar"}
           ]
         },
         %{
           name: "avatar_gravatar_type",
           label: "Gravatar Type: ",
           type: "string",
           input: :select,
           leading_break?: true,
           options: [
             %{label: "Default", value: "default"},
             %{label: "Wavatar", value: "wavatar"},
             %{label: "Monster ID", value: "monsterid"},
             %{label: "Identicon", value: "identicon"}
           ]
         },
         %{
           name: "avatar_gravatar_rating",
           label: "Gravatar Rating: ",
           type: "string",
           input: :select,
           leading_break?: true,
           options: [
             %{label: "G", value: "g"},
             %{label: "PG", value: "pg"},
             %{label: "R", value: "r"},
             %{label: "X", value: "x"}
           ]
         }
       ]},
      {"IP Ban",
       [
         %{
           name: "ipban_message",
           label: "Message to show to banned users:",
           label_sub: "(with $IP, $DATE, $ADMIN, $REASON, and $CONTACT)",
           type: "string",
           input: :textarea,
           rows: 4
         }
       ]},
      {"Media Engines",
       [
         %{name: "media_convert_path", label: "convert", type: "string"},
         %{name: "media_ffmpeg_path", label: "ffmpeg", type: "string"},
         %{name: "media_ffprobe_path", label: "ffprobe", type: "string"},
         %{name: "media_mem_limit", label: "Mem limit", type: "int"}
       ], :table},
      {"Video Options",
       [
         %{
           name: "video_playback_autoplay",
           label: "Autoplay",
           type: "bool",
           input: :bool_compact
         },
         %{name: "video_playback_loop", label: "Loop", type: "bool", input: :bool_compact},
         %{name: "video_playback_mute", label: "Mute", type: "bool", input: :bool_compact},
         %{
           name: "video_enabled_formats",
           label: "Enabled Formats (comma-separated)",
           type: "string"
         }
       ], :table},
      {"Tag Map Options",
       [
         %{kind: :label, html: "Only show tags used at least "},
         %{name: "tags_min", type: "int", input: :number},
         %{kind: :label, html: " times"},
         %{
           name: "tag_list_pages",
           label: "Paged tag lists: ",
           type: "bool",
           input: :bool,
           leading_break?: true
         }
       ]},
      {"Popular / Related Tag List",
       [
         %{kind: :label, html: "Show top "},
         %{name: "tag_list_length", type: "int", input: :number},
         %{kind: :label, html: " related tags"},
         %{kind: :label, html: "<br>Show top "},
         %{name: "popular_tag_list_length", type: "int", input: :number},
         %{kind: :label, html: " popular tags"},
         %{name: "info_link", label: "Tag info link: ", type: "string", leading_break?: true},
         %{
           name: "tag_list_omit_tags",
           label: "Omit tags: ",
           type: "string",
           leading_break?: true
         },
         %{
           name: "tag_list_image_type",
           label: "Post tag list: ",
           type: "string",
           input: :select,
           leading_break?: true,
           options: [
             %{label: "Post's tags only", value: "tags"},
             %{label: "Related tags only", value: "related"},
             %{label: "Both", value: "both"}
           ]
         },
         %{
           name: "tag_list_related_sort",
           label: "Sort related list by: ",
           type: "string",
           input: :select,
           leading_break?: true,
           options: [
             %{label: "Tag Count", value: "tagcount"},
             %{label: "Alphabetical", value: "alphabetical"}
           ]
         },
         %{
           name: "tag_list_popular_sort",
           label: "Sort popular list by: ",
           type: "string",
           input: :select,
           leading_break?: true,
           options: [
             %{label: "Tag Count", value: "tagcount"},
             %{label: "Alphabetical", value: "alphabetical"}
           ]
         },
         %{
           name: "tag_list_numbers",
           label: "Show tag counts",
           type: "bool",
           input: :bool,
           leading_break?: true
         }
       ]},
      {"Banned Phrases",
       [
         %{
           name: "banned_words",
           label: "One per line, lines that start with slashes are treated as regex",
           type: "string",
           input: :textarea,
           rows: 10
         }
       ]},
      {"Word Filter", [%{name: "word_filter", type: "string", input: :textarea, rows: 10}]},
      {"Home Page",
       [
         %{
           name: "home_links",
           label: "Page Links (Use BBCode, leave blank for defaults)",
           type: "string",
           input: :textarea,
           rows: 4
         },
         %{
           name: "home_text",
           label: "Page Text:",
           type: "string",
           input: :textarea,
           leading_break?: true,
           rows: 8
         },
         %{
           name: "home_counter",
           label: "Counter: ",
           type: "string",
           input: :select,
           leading_break?: true,
           options: counter_options
         }
       ]},
      {"Blotter",
       [
         %{
           name: "blotter_recent",
           label: "Number of recent entries to display: ",
           type: "int",
           input: :number
         },
         %{
           name: "blotter_color",
           label: "Color of important updates: (ABCDEF format) ",
           leading_break?: true,
           type: "string"
         },
         %{
           name: "blotter_position",
           label: "Position: ",
           type: "string",
           input: :select,
           leading_break?: true,
           options: [
             %{label: "Top of page", value: "subheading"},
             %{label: "In navigation bar", value: "left"}
           ]
         }
       ]},
      {"Site Description",
       [
         %{name: "site_description", label: "Description: ", type: "string"},
         %{name: "site_keywords", label: "Keywords: ", type: "string", leading_break?: true}
       ]},
      {"Google Analytics",
       [
         %{name: "google_analytics_id", label: "Analytics ID: ", type: "string"},
         %{kind: :label, html: "<br>(eg. UA-xxxxxxxx-x)"}
       ]},
      {"Browser Search",
       [
         %{
           name: "search_suggestions_results_order",
           label: "Sort the suggestions by:",
           type: "string",
           input: :select,
           options: [
             %{label: "Alphabetical", value: "a"},
             %{label: "Tag Count", value: "t"},
             %{label: "Disabled", value: "n"}
           ]
         }
       ]},
      {"Archive Handler Options",
       [
         %{name: "archive_tmp_dir", label: "Temporary folder: ", type: "string"},
         %{
           name: "archive_extract_command",
           label: "Extraction command: ",
           leading_break?: true,
           type: "string"
         },
         %{kind: :label, html: "<br>%f for archive, %d for temporary directory"}
       ]},
      {"Random Post",
       [
         %{name: "show_random_block", label: "Show Random Block: ", type: "bool", input: :bool}
       ]},
      {"Random Posts List",
       [
         %{
           name: "random_images_list_count",
           label: "Amount of Random posts to display ",
           type: "int",
           input: :number
         }
       ]},
      {"Custom HTML Headers",
       [
         %{
           name: "custom_html_headers",
           label: "HTML Code to place within <head></head> on all pages",
           type: "string",
           input: :textarea,
           rows: 8
         },
         %{
           name: "sitename_in_title",
           label: "Add website name in title",
           type: "string",
           input: :select,
           leading_break?: true,
           options: [
             %{label: "none", value: "none"},
             %{label: "as prefix", value: "prefix"},
             %{label: "as suffix", value: "suffix"}
           ]
         }
       ]},
      {"Wiki",
       [
         %{
           name: "wiki_revisions",
           label: "Enable wiki revisions: ",
           type: "bool",
           input: :bool
         },
         %{
           name: "wiki_tag_page_template",
           label: "Tag page template: ",
           type: "string",
           input: :textarea,
           leading_break?: true,
           rows: 6
         },
         %{
           name: "wiki_empty_taginfo",
           label: "Empty list text: ",
           type: "string",
           leading_break?: true
         },
         %{
           name: "shortwikis_on_tags",
           label: "Show shortwiki entry when searching for a single tag: ",
           type: "bool",
           input: :bool,
           leading_break?: true
         }
       ]},
      {"Sitemap",
       [
         %{
           name: "sitemap_generatefull",
           label: "Generate full sitemap",
           type: "bool",
           input: :bool
         },
         %{
           kind: :label,
           html:
             "<br>(Enabled: every image and tag in sitemap, generation takes longer)<br>(Disabled: only display the last 50 uploads in the sitemap)"
         }
       ]},
      {"Remote API Integration",
       [
         %{kind: :label, html: "<a href='https://akismet.com/'>Akismet</a>"},
         %{
           name: "comment_wordpress_key",
           label: "API key: ",
           type: "string",
           leading_break?: true
         },
         %{
           kind: :label,
           html: "<br>&nbsp;<br><a href='https://www.google.com/recaptcha/admin'>ReCAPTCHA</a>"
         },
         %{
           name: "api_recaptcha_privkey",
           label: "Secret key: ",
           type: "string",
           leading_break?: true
         },
         %{
           name: "api_recaptcha_pubkey",
           label: "Site key: ",
           type: "string",
           leading_break?: true
         }
       ]}
    ]

    {sections, used_names} =
      Enum.reduce(specs, {[], MapSet.new()}, fn
        {title, fields}, {acc_sections, acc_used} ->
          section = build_setup_section(title, fields, entries_map, :default)

          {acc_sections ++ [section], mark_used_names(acc_used, section.fields)}

        {title, fields, layout}, {acc_sections, acc_used} ->
          section = build_setup_section(title, fields, entries_map, layout)

          {acc_sections ++ [section], mark_used_names(acc_used, section.fields)}
      end)

    leftover_fields =
      entries
      |> Enum.reject(&MapSet.member?(used_names, &1.name))
      |> Enum.sort_by(fn entry -> String.downcase(entry.name) end)
      |> Enum.map(fn entry ->
        %{
          name: entry.name,
          label: "#{entry.name}: ",
          value: entry.value,
          input: infer_input_type(entry.name, entry.value),
          type: infer_store_type(entry.name, entry.value),
          rows: if(String.contains?(entry.value, "\n"), do: 4, else: nil),
          leading_break?: false
        }
      end)

    other_section = %{
      title: "Other Settings",
      dom_id: "Other_Settings-setup",
      layout: :default,
      fields: leftover_fields
    }

    sections ++ [other_section]
  end

  defp home_counter_options do
    counters_dir =
      case Site.legacy_root() do
        root when is_binary(root) and root != "" -> Path.join(root, "ext/home/counters")
        _ -> nil
      end

    names =
      cond do
        is_nil(counters_dir) or not File.dir?(counters_dir) ->
          []

        true ->
          counters_dir
          |> File.ls!()
          |> Enum.filter(fn name -> File.dir?(Path.join(counters_dir, name)) end)
          |> Enum.sort()
      end
      |> then(fn list -> if "default" in list, do: list, else: ["default" | list] end)
      |> Enum.uniq()

    names
    |> Enum.map(fn name ->
      %{
        label: name |> String.replace("_", " ") |> String.capitalize(),
        value: name
      }
    end)
  end

  defp build_setup_section(title, fields, entries_map, layout) do
    rendered_fields =
      Enum.map(fields, fn
        %{kind: :label} = field ->
          field

        %{kind: :nicetest} = field ->
          field

        field ->
          name = field.name
          value = Map.get(entries_map, name, "")

          Map.merge(
            %{
              value: value,
              input: :text,
              leading_break?: false,
              label: nil,
              label_sub: nil,
              options: nil,
              type: "string",
              rows: nil
            },
            field
          )
      end)

    %{
      title: title,
      dom_id: setup_dom_id(title),
      layout: layout,
      fields: rendered_fields
    }
  end

  defp mark_used_names(used, fields) do
    Enum.reduce(fields, used, fn field, acc ->
      case field do
        %{name: name} when is_binary(name) and name != "" -> MapSet.put(acc, name)
        _ -> acc
      end
    end)
  end

  defp setup_dom_id(title) do
    safe = title |> String.replace(~r/[^a-zA-Z0-9]/, "_")
    "#{safe}-setup"
  end

  defp infer_input_type(name, value) do
    cond do
      String.contains?(value, "\n") or String.length(value) > 160 -> :textarea
      infer_store_type(name, value) == "bool" -> :bool
      infer_store_type(name, value) == "int" -> :number
      true -> :text
    end
  end

  defp infer_store_type(name, value) do
    lowered = String.downcase(to_string(value))

    cond do
      name in ["nice_urls"] ->
        "bool"

      lowered in ["0", "1", "true", "false", "y", "n", "yes", "no", "on", "off"] and
          boolish_name?(name) ->
        "bool"

      integer_like?(value) ->
        "int"

      true ->
        "string"
    end
  end

  defp boolish_name?(name) do
    String.contains?(name, "enable") or String.ends_with?(name, "_tlsource") or
      String.ends_with?(name, "_meta") or String.ends_with?(name, "_enabled") or
      String.starts_with?(name, "can_")
  end

  defp integer_like?(value) do
    case Integer.parse(to_string(value)) do
      {_, ""} -> true
      _ -> false
    end
  end

  defp cast_setup_value(type, raw_value) do
    value = normalize_form_value(raw_value)

    case to_string(type) do
      "bool" -> if(truthy_form_value?(value), do: "Y", else: "N")
      "int" -> value |> parse_shorthand_int() |> Integer.to_string()
      _ -> value
    end
  end

  defp truthy_form_value?(value) do
    String.downcase(to_string(value)) in ["1", "true", "on", "yes", "y", "t"]
  end

  defp parse_shorthand_int(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Regex.run(~r/^([0-9]+(?:\.[0-9]+)?)\s*([kmgt]?b?)?$/i, trimmed) do
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
          {n, ""} -> trunc(n * multiplier)
          _ -> 0
        end

      _ ->
        case Integer.parse(trimmed) do
          {n, ""} -> n
          _ -> 0
        end
    end
  end

  defp parse_shorthand_int(value), do: value |> to_string() |> parse_shorthand_int()

  defp normalize_form_value(values) when is_list(values) do
    values
    |> List.last()
    |> normalize_form_value()
  end

  defp normalize_form_value(nil), do: ""
  defp normalize_form_value(value) when is_binary(value), do: value
  defp normalize_form_value(value), do: to_string(value)

  defp maybe_decode_user_name(nil), do: nil

  defp maybe_decode_user_name(value) do
    value
    |> to_string()
    |> URI.decode()
    |> String.trim()
    |> case do
      "" -> nil
      name -> name
    end
  end

  defp with_user_id(params) when is_map(params) do
    case Map.get(params, "id") do
      value when is_binary(value) and value != "" ->
        params

      value when is_integer(value) and value > 0 ->
        params

      _ ->
        case Map.get(params, "user_id") do
          nil -> params
          user_id -> Map.put(params, "id", user_id)
        end
    end
  end

  defp with_user_id(params), do: params

  defp ensure_target_user_id(params, actor) when is_map(params) do
    cond do
      Map.get(params, "id") in [nil, ""] and actor && actor.id ->
        Map.put(params, "id", actor.id)

      true ->
        params
    end
  end

  defp ensure_target_user_id(params, _actor), do: params

  defp self_target?(%{id: actor_id}, params) when is_integer(actor_id) and is_map(params) do
    case Map.get(params, "id") do
      id when is_integer(id) -> id == actor_id
      id when is_binary(id) -> String.trim(id) == Integer.to_string(actor_id)
      _ -> false
    end
  end

  defp self_target?(_, _), do: false

  defp redirect_after_password_change(true, kind, message) do
    encoded = URI.encode_www_form(message)
    "/user?#{kind}=#{encoded}"
  end

  defp redirect_after_password_change(false, kind, message) do
    encoded = URI.encode_www_form(message)
    "/user_admin/list?#{kind}=#{encoded}"
  end

  defp error_message(:invalid_credentials), do: "Invalid username or password"
  defp error_message(:missing_credentials), do: "Missing credentials"
  defp error_message(:invalid_username), do: "Invalid username"
  defp error_message(:username_taken), do: "That username is already taken"
  defp error_message(:password_mismatch), do: "Passwords do not match"
  defp error_message(:invalid_password), do: "Password cannot be empty"
  defp error_message(:email_required), do: "Email address is required"
  defp error_message(:invalid_email), do: "Invalid email address"
  defp error_message(:not_logged_in), do: "You are not logged in"
  defp error_message(:permission_denied), do: "Permission denied"
  defp error_message(:invalid_user_id), do: "Invalid user id"
  defp error_message(:user_not_found), do: "User not found"
  defp error_message(:cannot_delete_anon), do: "Cannot delete anonymous user"
  defp error_message(:pass_column_missing), do: "Password column is missing in users table"
  defp error_message(:email_column_missing), do: "Email column is missing in users table"
  defp error_message(:invalid_class), do: "Invalid class"
  defp error_message(:delete_failed), do: "Failed to delete user"
  defp error_message(:create_failed), do: "Failed to create account"
  defp error_message(:update_failed), do: "Failed to update user"
  defp error_message(_), do: "Action failed"

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
end
