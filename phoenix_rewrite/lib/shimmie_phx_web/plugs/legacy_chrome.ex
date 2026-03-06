defmodule ShimmiePhoenixWeb.Plugs.LegacyChrome do
  @moduledoc false
  import Plug.Conn

  alias ShimmiePhoenix.Site.Appearance
  alias ShimmiePhoenix.Site.Approval
  alias ShimmiePhoenix.Site.Help
  alias ShimmiePhoenix.Site.Pages
  alias ShimmiePhoenix.Site.PrivateMessages
  alias ShimmiePhoenix.Site.Store
  alias ShimmiePhoenix.Site.Users

  def init(opts), do: opts

  def call(conn, _opts) do
    path = conn.request_path
    show_chrome = path not in ["/", "/home"]
    category = category_for(path)
    current_user = conn.assigns[:legacy_user] || Users.current_user(conn)

    chrome = %{
      show?: show_chrome,
      site_title: Appearance.site_title(),
      nav_links: nav_links(category, current_user),
      sub_links: sub_links(category, path, current_user),
      blotter_entries: if(show_chrome, do: Pages.list_blotter(blotter_recent()), else: []),
      contact_href: Appearance.contact_href(),
      post_count: Store.count_posts()
    }

    conn
    |> assign(:legacy_user, current_user)
    |> assign(:legacy_chrome, chrome)
  end

  defp blotter_recent do
    case Store.get_config("blotter_recent", "7") |> to_string() |> Integer.parse() do
      {n, ""} when n > 0 -> n
      _ -> 7
    end
  end

  defp category_for(path) do
    cond do
      String.starts_with?(path, "/user_admin/list") -> :system
      String.starts_with?(path, "/upload") -> :upload
      String.starts_with?(path, "/comment") -> :comments
      String.starts_with?(path, "/help") -> :help
      String.starts_with?(path, "/system") -> :system
      String.starts_with?(path, "/ext_doc") -> :system
      String.starts_with?(path, "/ext_manager") -> :system
      String.starts_with?(path, "/setup") -> :system
      String.starts_with?(path, "/admin") -> :system
      String.starts_with?(path, "/permissions") -> :system
      String.starts_with?(path, "/system_info") -> :system
      String.starts_with?(path, "/cron_upload") -> :system
      String.starts_with?(path, "/blotter/editor") -> :system
      String.starts_with?(path, "/ip_ban") -> :system
      String.starts_with?(path, "/source_history") -> :system
      String.starts_with?(path, "/tag_history") -> :system
      String.starts_with?(path, "/blotter") -> :none
      String.starts_with?(path, "/tags") -> :tags
      String.starts_with?(path, "/wiki") -> :wiki
      String.starts_with?(path, "/pm") -> :account
      String.starts_with?(path, "/user") -> :account
      String.starts_with?(path, "/user_admin/login") -> :account
      String.starts_with?(path, "/post") or String.starts_with?(path, "/random") -> :posts
      true -> :posts
    end
  end

  defp nav_links(category, current_user) do
    account_href = if logged_in?(current_user), do: "/user", else: "/user_admin/login"

    [
      nav(account_href, "Account", category == :account),
      nav("/post/list", "Posts", category == :posts),
      nav("/upload", "Upload", category == :upload),
      nav("/comment/list", "Comments", category == :comments),
      nav("/help", "Help", category == :help),
      nav("/system", "System", category == :system),
      nav("/tags/map", "Tags", category == :tags),
      nav("/wiki", "Wiki", category == :wiki)
    ]
  end

  defp sub_links(:posts, path, current_user) do
    favorites_user =
      case current_user do
        %{name: name} when is_binary(name) and name != "" -> name
        _ -> "Anonymous"
      end

    base = [
      nav(
        "/post/list",
        "All",
        String.starts_with?(path, "/post/list") and not pending_approval_path?(path)
      ),
      nav(
        "/post/list/favorited_by=#{URI.encode(favorites_user)}/1",
        "My Favorites",
        String.contains?(path, "favorited_by=")
      ),
      nav("/random_image/view", "Random Post", String.starts_with?(path, "/random_image/view")),
      nav("/random", "Shuffle", String.starts_with?(path, "/random"))
    ]

    if Approval.can_approve?(current_user) do
      List.insert_at(
        base,
        2,
        nav("/post/list/approved=no/1", "Pending Approval", pending_approval_path?(path))
      )
    else
      base
    end
  end

  defp sub_links(:upload, _path, _current_user),
    do: [nav("/wiki/upload_guidelines", "Guidelines", false)]

  defp sub_links(:comments, path, _current_user) do
    [
      nav("/comment/list", "All", String.starts_with?(path, "/comment/list")),
      nav("/ext_doc/comment", "Help", String.starts_with?(path, "/ext_doc/comment"))
    ]
  end

  defp sub_links(:help, path, _current_user) do
    Enum.map(Help.topics(), fn {topic, label} ->
      href = "/help/#{topic}"
      nav(href, label, String.starts_with?(path, href))
    end)
  end

  defp sub_links(:system, path, current_user) do
    system_links(current_user)
    |> Enum.map(fn {href, label} -> nav(href, label, system_link_active?(path, href)) end)
  end

  defp sub_links(:tags, path, _current_user) do
    [
      nav("/auto_tag/list", "Auto-Tag", String.starts_with?(path, "/auto_tag/list")),
      nav("/ext_doc/tag_edit", "Help", String.starts_with?(path, "/ext_doc/tag_edit")),
      nav("/tags/map", "Map", String.starts_with?(path, "/tags/map")),
      nav("/tags/alphabetic", "Alphabetic", String.starts_with?(path, "/tags/alphabetic")),
      nav("/tags/popularity", "Popularity", String.starts_with?(path, "/tags/popularity")),
      nav("/alias/list", "Aliases", String.starts_with?(path, "/alias/list"))
    ]
  end

  defp sub_links(:wiki, path, _current_user) do
    [
      nav("/wiki/rules", "Rules", String.starts_with?(path, "/wiki/rules")),
      nav("/ext_doc/wiki", "Help", String.starts_with?(path, "/ext_doc/wiki")),
      nav("/wiki/wiki:list", "Page list", String.starts_with?(path, "/wiki/wiki:list"))
    ]
  end

  defp sub_links(:account, path, current_user) do
    if logged_in?(current_user) do
      user_name =
        current_user
        |> Map.get(:name, "")
        |> to_string()
        |> URI.encode()

      pm_label =
        case PrivateMessages.unread_count(current_user) do
          count when is_integer(count) and count > 0 -> "Private Messages (#{count})"
          _ -> "Private Messages"
        end

      [
        nav("/user_config", "User Options", String.starts_with?(path, "/user_config")),
        nav(
          "/post/list/favorited_by=#{user_name}/1",
          "My Favorites",
          String.contains?(path, "favorited_by=")
        ),
        nav(
          "/user#private-messages",
          pm_label,
          String.starts_with?(path, "/user") or String.starts_with?(path, "/pm")
        ),
        nav("/user_admin/logout", "Log Out", false)
      ]
    else
      []
    end
  end

  defp sub_links(:none, _path, _current_user), do: []
  defp sub_links(_, _, _), do: []

  defp pending_approval_path?(path) do
    String.contains?(path, "approved=no") or String.contains?(path, "approved%3Dno")
  end

  defp logged_in?(%{id: id}) when is_integer(id) and id > 0, do: true
  defp logged_in?(_), do: false

  defp admin?(%{class: class}) do
    class
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> Kernel.==("admin")
  end

  defp admin?(_), do: false

  defp system_links(current_user) do
    enabled = Pages.enabled_extension_keys() |> MapSet.new()

    if admin?(current_user) do
      [
        {"/setup", "Board Config"},
        {"/system_info", "System Info"},
        {"/ext_manager", "Extension Manager"},
        {"/user_admin/list", "User List"},
        {"/auto_tag/list", "Auto-Tag"},
        {"/alias/list", "Aliases"},
        {"/admin", "Board Admin"},
        {"/permissions", "Permissions Editor"},
        if_enabled(enabled, "ipban", {"/ip_ban/list", "IP Bans"}),
        if_enabled(enabled, "source_history", {"/source_history/all/1", "Source Changes"}),
        if_enabled(enabled, "tag_history", {"/tag_history/all/1", "Tag Changes"}),
        if_enabled(enabled, "blotter", {"/blotter/editor", "Blotter Editor"}),
        if_enabled(enabled, "cron_uploader", {"/cron_upload", "Cron Upload"})
      ]
      |> Enum.reject(&is_nil/1)
    else
      [
        {"/ext_doc", "Board Help"},
        if_enabled(enabled, "cron_uploader", {"/cron_upload", "Cron Upload"})
      ]
      |> Enum.reject(&is_nil/1)
    end
  end

  defp if_enabled(enabled_extensions, key, link) do
    if MapSet.member?(enabled_extensions, key), do: link, else: nil
  end

  defp system_link_active?(path, "/source_history/all/1"),
    do: String.starts_with?(path, "/source_history")

  defp system_link_active?(path, "/tag_history/all/1"),
    do: String.starts_with?(path, "/tag_history")

  defp system_link_active?(path, "/ip_ban/list"), do: String.starts_with?(path, "/ip_ban")
  defp system_link_active?(path, href), do: String.starts_with?(path, href)

  defp nav(href, label, active?) do
    %{href: href, label: label, active?: active?}
  end
end
