defmodule ShimmiePhoenixWeb.PostController do
  use ShimmiePhoenixWeb, :controller

  alias ShimmiePhoenix.Site.Appearance
  alias ShimmiePhoenix.Site.Approval
  alias ShimmiePhoenix.Site.Comments
  alias ShimmiePhoenix.Site.Posts
  alias ShimmiePhoenix.Site.Index
  alias ShimmiePhoenix.Site.PostAdmin
  alias ShimmiePhoenix.Site.PostSet
  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.Site.TagEdit
  alias ShimmiePhoenix.Site.TelegramAlerts
  alias ShimmiePhoenix.Site.Favorites
  alias ShimmiePhoenix.Site.Users

  def view(conn, %{"image_id" => image_id}) do
    case normalize_image_id(image_id) do
      {:redirect, id, search_term} ->
        redirect(conn, to: "/post/view/#{id}#search=#{URI.encode_www_form(search_term)}")

      {:ok, id} ->
        case Posts.get_post(id) do
          nil ->
            send_resp(conn, 404, "Not Found")

          post ->
            post = Map.merge(post, Posts.post_extra(id))
            favorite_users = Favorites.list_favorited_by(id)
            owner_name = Posts.owner_name(id)
            tag_rows = Posts.tag_rows(id)
            comments = Posts.comments(id)
            current_user = conn.assigns[:legacy_user] || Users.current_user(conn)
            remote_ip = Users.remote_ip_string(conn)
            recaptcha_key = to_string(Store.get_config("api_recaptcha_pubkey", "") || "")
            comment_captcha_enabled? =
              String.upcase(to_string(Store.get_config("comment_captcha", "N"))) == "Y"

            show_captcha =
              comment_captcha_enabled? and not Comments.bypass_comment_checks?(current_user)

            show_approval_controls =
              Approval.can_approve?(current_user) and Approval.approval_supported?()

            post_approved =
              if(show_approval_controls, do: Approval.image_approved?(id), else: true)

            notes_json =
              id
              |> PostAdmin.notes_for_image()
              |> Jason.encode!()

            logged_in? = PostAdmin.logged_in?(current_user)
            admin? = PostAdmin.admin?(current_user)
            can_delete_comments = Comments.can_delete_comment?(current_user)
            can_view_comment_ips = Comments.can_view_ip?(current_user)
            can_ban_comment_ips = Comments.can_ban_ip?(current_user)
            uploader_ip = post |> Map.get(:owner_ip) |> to_string() |> String.trim()
            can_edit_tags = TagEdit.can_edit_tags?(current_user)
            can_edit_post_info = PostSet.can_edit_post_info?(current_user)
            tag_edit_value = Enum.join(post.tags || [], " ")

            favorited_by_current_user =
              if logged_in? do
                Enum.any?(favorite_users, fn name ->
                  String.downcase(to_string(name || "")) ==
                    String.downcase(to_string(current_user.name || ""))
                end)
              else
                false
              end

            conn
            |> assign(:page_title, "#{Appearance.site_title()} - ")
            |> assign(:has_left_nav, true)
            |> assign(:include_notes_assets, true)
            |> assign(:include_view_assets, true)
            |> assign(:meta_keywords, Enum.join(post.tags || [], ", "))
            |> assign(:meta_og_title, Enum.join(post.tags || [], ", "))
            |> assign(:meta_og_type, "article")
            |> assign(:meta_og_image, absolute_url(conn, Posts.thumb_route(post)))
            |> assign(:meta_og_url, absolute_url(conn, "/post/view/#{id}"))
            |> render(:show,
              comment_placeholder: normalize_comment_placeholder(conn.params["error"]),
              post: post,
              owner_name: owner_name,
              tag_rows: tag_rows,
              comments: comments,
              favorite_users: favorite_users,
              rating_label: Posts.rating_label(Map.get(post, :rating, "?")),
              source_text:
                if(is_binary(post.source) and post.source != "", do: post.source, else: "Unknown"),
              source_href: post.source,
              locked_label: if(Map.get(post, :locked, false), do: "Yes", else: "No"),
              parent_id: Map.get(post, :parent_id),
              recaptcha_key: recaptcha_key,
              show_captcha: show_captcha and recaptcha_key != "",
              show_approval_controls: show_approval_controls,
              post_approved: post_approved,
              logged_in?: logged_in?,
              admin?: admin?,
              can_delete_comments: can_delete_comments,
              can_view_comment_ips: can_view_comment_ips,
              can_ban_comment_ips: can_ban_comment_ips,
              can_view_uploader_ip: can_view_comment_ips,
              can_ban_uploader_ip: can_ban_comment_ips,
              uploader_ip: uploader_ip,
              can_edit_tags: can_edit_tags,
              can_edit_post_info: can_edit_post_info,
              tag_edit_value: tag_edit_value,
              favorited_by_current_user: favorited_by_current_user,
              comment_form_hash: Comments.form_hash(remote_ip),
              notes_json: notes_json
            )
        end

      :error ->
        send_resp(conn, 404, "Not Found")
    end
  end

  defp normalize_comment_placeholder(nil), do: "Add your comment"

  defp normalize_comment_placeholder(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "Add your comment"
      message -> message
    end
  end

  def approve(conn, params), do: set_approval(conn, params, true)
  def disapprove(conn, params), do: set_approval(conn, params, false)

  def edit_tags(conn, params) do
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)
    remote_ip = Users.remote_ip_string(conn)

    case TagEdit.update_tags(params["image_id"], params["tags"], current_user, remote_ip) do
      :ok ->
        redirect(conn, to: "/post/view/#{params["image_id"]}")

      {:error, :permission_denied} ->
        send_resp(conn, 403, "Permission Denied")

      {:error, :invalid_image_id} ->
        send_resp(conn, 400, "Bad Request")

      {:error, :post_not_found} ->
        send_resp(conn, 404, "Not Found")

      _ ->
        send_resp(conn, 500, "Tag Update Failed")
    end
  end

  def set_info(conn, params) do
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)
    remote_ip = Users.remote_ip_string(conn)
    image_id = params["image_id"]

    case PostSet.apply(image_id, params, current_user, remote_ip) do
      :ok ->
        redirect(conn, to: "/post/view/#{image_id}")

      {:error, :permission_denied} ->
        send_resp(conn, 403, "Permission Denied")

      {:error, :invalid_image_id} ->
        send_resp(conn, 400, "Bad Request")

      {:error, :post_not_found} ->
        send_resp(conn, 404, "Not Found")

      _ ->
        send_resp(conn, 500, "Post Update Failed")
    end
  end

  def list(conn, params) do
    case search_redirect_path(params) do
      nil ->
        {search, page_number} = search_and_page(params)
        page_size = Index.posts_per_page()
        current_user = conn.assigns[:legacy_user] || Users.current_user(conn)

        {posts, total_posts} =
          Index.list_posts(search, page_number, page_size, current_user: current_user)

        if search != "" and page_number == 1 and total_posts == 1 do
          case posts do
            [%{id: id}] -> redirect(conn, to: "/post/view/#{id}")
            _ -> render_list(conn, search, page_number, page_size, posts, total_posts)
          end
        else
          render_list(conn, search, page_number, page_size, posts, total_posts)
        end

      redirect_path ->
        redirect(conn, to: redirect_path)
    end
  end

  defp render_list(conn, search, page_number, page_size, posts, total_posts) do
    total_pages = max(1, div(total_posts + page_size - 1, page_size))
    current_page = min(max(page_number, 1), total_pages)
    title = if search == "", do: Appearance.site_title(), else: search
    decorated_posts = Enum.map(posts, &decorate_post/1)

    preload_images =
      if pending_approval_search?(search),
        do: [],
        else: Enum.map(decorated_posts, &Posts.thumb_route/1)

    featured_post = featured_sidebar_post()
    popular_tags = popular_tags_sidebar(search)

    conn
    |> assign(:page_title, title)
    |> assign(:has_left_nav, true)
    |> assign(:preload_images, preload_images)
    |> render(:list,
      search: search,
      data_query: data_query(search),
      page_number: current_page,
      total_pages: total_pages,
      prev_path: if(current_page > 1, do: search_page_path(search, current_page - 1), else: nil),
      next_path:
        if(current_page < total_pages, do: search_page_path(search, current_page + 1), else: nil),
      paginator_pages: paginator_pages(search, current_page, total_pages),
      posts: decorated_posts,
      featured_post: featured_post,
      popular_tags: popular_tags
    )
  end

  defp pending_approval_search?(search) do
    search
    |> to_string()
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.any?(&(&1 in ["approved=no", "approved:no"]))
  end

  defp search_redirect_path(%{"search" => raw_search}) when is_binary(raw_search) do
    search = String.trim(raw_search)
    if search == "", do: nil, else: search_page_path(search, 1)
  end

  defp search_redirect_path(_), do: nil

  defp search_and_page(%{"path_search" => path_search, "page_num" => page_num}) do
    {decode_search(path_search), parse_page_number(page_num)}
  end

  defp search_and_page(%{"arg1" => arg1}) do
    case Integer.parse(arg1) do
      {page, ""} when page > 0 -> {"", page}
      _ -> {decode_search(arg1), 1}
    end
  end

  defp search_and_page(_), do: {"", 1}

  defp parse_page_number(value) do
    case Integer.parse(to_string(value || "")) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end

  defp decode_search(value) do
    value
    |> to_string()
    |> URI.decode()
    |> String.trim()
  end

  defp data_query(""), do: ""
  defp data_query(search), do: "#search=" <> URI.encode_www_form(search)

  defp search_page_path("", 1), do: "/post/list"
  defp search_page_path("", page), do: "/post/list/#{page}"
  defp search_page_path(search, page), do: "/post/list/#{Index.search_to_path(search)}/#{page}"

  defp paginator_pages(_search, _page_number, total_pages) when total_pages <= 0, do: []

  defp paginator_pages(search, page_number, total_pages) do
    start_page = max(page_number - 5, 1)
    end_page = min(start_page + 10, total_pages)

    Enum.map(start_page..end_page, fn page ->
      %{page: page, current?: page == page_number, path: search_page_path(search, page)}
    end)
  end

  defp decorate_post(post) do
    tags = Map.get(post, :tags, [])
    mime = MIME.from_path("file.#{post.ext}") || "application/octet-stream"
    {thumb_width, thumb_height} = thumbnail_size(post.width, post.height)
    tooltip = tooltip_text(tags, post.width, post.height, post.filesize)

    post
    |> Map.put(:data_tags, String.downcase(Enum.join(tags, " ")))
    |> Map.put(:mime, mime)
    |> Map.put(:thumb_width, thumb_width)
    |> Map.put(:thumb_height, thumb_height)
    |> Map.put(:tooltip, tooltip)
  end

  defp thumbnail_size(width, height) do
    thumb_width = config_int("thumb_width", 192)
    thumb_height = config_int("thumb_height", 192)
    w = if width > 0, do: width, else: 192
    h = if height > 0, do: height, else: 192
    w = if w > h * 5, do: h * 5, else: w
    h = if h > w * 5, do: w * 5, else: h
    scale = min(thumb_width / w, thumb_height / h)

    {
      max(1, trunc(w * scale)),
      max(1, trunc(h * scale))
    }
  end

  defp config_int(name, default) do
    case Store.get_config(name, Integer.to_string(default)) |> to_string() |> Integer.parse() do
      {value, ""} when value > 0 -> value
      _ -> default
    end
  end

  defp tooltip_text(tags, width, height, filesize) do
    tag_text =
      case tags do
        [] -> "(no tags)"
        _ -> Enum.join(tags, " ")
      end

    "#{tag_text} // #{width}x#{height} // #{human_filesize(filesize)}"
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

  defp featured_sidebar_post do
    with {id, ""} <- Integer.parse(to_string(Store.get_config("featured_id", "") || "")),
         post when not is_nil(post) <- Posts.get_post(id) do
      decorate_post(post)
    else
      _ -> nil
    end
  end

  defp popular_tags_sidebar(search) do
    if search != "" do
      []
    else
      limit =
        case Integer.parse(to_string(Store.get_config("popular_tag_list_length", "15") || "15")) do
          {n, ""} when n > 0 -> n
          _ -> 15
        end

      omit_patterns =
        Store.get_config("tag_list_omit_tags", "")
        |> to_string()
        |> String.split(~r/[,\s]+/, trim: true)

      info_link_template =
        Store.get_config("tag_list_info_link", "https://en.wikipedia.org/wiki/$tag")
        |> to_string()

      Index.popular_tags(limit, omit_patterns)
      |> Enum.map(fn row ->
        Map.merge(row, %{
          info_link: String.replace(info_link_template, "$tag", URI.encode(row.tag)),
          href: "/post/list/#{URI.encode(row.tag)}/1",
          display_name: String.replace(row.tag, "_", " ")
        })
      end)
    end
  end

  defp absolute_url(conn, path) do
    port =
      case conn.port do
        80 -> ""
        443 -> ""
        value -> ":#{value}"
      end

    "#{conn.scheme}://#{conn.host}#{port}#{path}"
  end

  defp normalize_image_id(image_id) when is_binary(image_id) do
    case Integer.parse(image_id) do
      {id, ""} when id > 0 ->
        {:ok, id}

      {id, rest} when id > 0 ->
        case String.trim_leading(rest, "?") do
          "search=" <> search_term when search_term != "" ->
            {:redirect, id, search_term}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp normalize_image_id(_), do: :error

  defp set_approval(conn, params, approved?) do
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)

    with {:ok, image_id} <- parse_approval_image_id(params),
         :ok <- set_image_approval(image_id, current_user, approved?) do
      if approved? do
        TelegramAlerts.notify_post_approved(image_id, current_user)
      end

      redirect(conn, to: "/post/view/#{image_id}")
    else
      {:error, :permission_denied} ->
        send_resp(conn, 403, "Permission Denied")

      {:error, :post_not_found} ->
        send_resp(conn, 404, "Not Found")

      {:error, :approval_not_supported} ->
        send_resp(conn, 400, "Bad Request")

      {:error, :invalid_image_id} ->
        send_resp(conn, 400, "Bad Request")

      {:error, _} ->
        send_resp(conn, 500, "Approval Operation Failed")

      _ ->
        send_resp(conn, 400, "Bad Request")
    end
  end

  defp set_image_approval(image_id, current_user, true),
    do: Approval.approve(image_id, current_user)

  defp set_image_approval(image_id, current_user, false),
    do: Approval.disapprove(image_id, current_user)

  defp parse_approval_image_id(params) do
    value =
      cond do
        is_map(params) and Map.has_key?(params, "image_id") -> Map.get(params, "image_id")
        is_map(params) and Map.has_key?(params, "id") -> Map.get(params, "id")
        true -> nil
      end

    case Integer.parse(to_string(value || "")) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_image_id}
    end
  end

end
