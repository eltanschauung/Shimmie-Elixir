defmodule ShimmiePhoenixWeb.Router do
  use ShimmiePhoenixWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug ShimmiePhoenixWeb.Plugs.IPBan
    plug ShimmiePhoenixWeb.Plugs.LegacyChrome
    plug :put_root_layout, html: {ShimmiePhoenixWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "referrer-policy" => "strict-origin-when-cross-origin",
      "x-permitted-cross-domain-policies" => "none"
    }
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :legacy_static do
    plug :put_secure_browser_headers, %{
      "referrer-policy" => "strict-origin-when-cross-origin",
      "x-permitted-cross-domain-policies" => "none"
    }
  end

  pipeline :compat_mutation do
    plug :accepts, ["html", "json"]
    plug :fetch_session
    plug ShimmiePhoenixWeb.Plugs.IPBan
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "referrer-policy" => "strict-origin-when-cross-origin",
      "x-permitted-cross-domain-policies" => "none"
    }
  end

  scope "/", ShimmiePhoenixWeb do
    pipe_through :legacy_static

    get "/favicon.ico", LegacyAssetController, :favicon
    get "/apple-touch-icon.png", LegacyAssetController, :apple_touch_icon
    get "/data/*path", LegacyAssetController, :data
    get "/ext/*path", LegacyAssetController, :ext
    get "/themes/*path", LegacyAssetController, :themes

    get "/image/:image_id/:filename", MediaController, :image
    get "/thumb/:image_id/:filename", MediaController, :thumb
  end

  scope "/", ShimmiePhoenixWeb do
    pipe_through :browser

    get "/", HomeController, :root
    get "/home", HomeController, :home
    get "/post/view/:image_id", PostController, :view
    get "/post/list", PostController, :list
    get "/post/list/:path_search/:page_num", PostController, :list
    get "/post/list/:arg1", PostController, :list

    get "/comment/list", LegacyPagesController, :comment_list
    get "/comment/list/:page_num", LegacyPagesController, :comment_list
    get "/comment/delete/:comment_id/:image_id", CommentController, :delete
    get "/upload", LegacyPagesController, :upload
    get "/tags", LegacyPagesController, :tags_root
    get "/tags/:sub", LegacyPagesController, :tags
    get "/auto_tag/list", LegacyPagesController, :auto_tag_list
    get "/alias/list", LegacyPagesController, :alias_list
    get "/help", LegacyPagesController, :help_root
    get "/help/:topic", LegacyPagesController, :help_topic
    get "/nicetest", LegacyPagesController, :nicetest
    get "/system", LegacyPagesController, :system
    get "/setup", LegacyPagesController, :setup
    post "/setup/save", LegacyPagesController, :setup_save
    post "/setup/config", LegacyPagesController, :setup_config
    post "/setup/theme", LegacyPagesController, :setup_theme
    get "/system_info", LegacyPagesController, :system_info
    get "/ext_doc", LegacyPagesController, :ext_doc
    get "/ext_doc/:topic", LegacyPagesController, :ext_doc_topic
    get "/ext_manager", LegacyPagesController, :ext_manager
    get "/admin", LegacyPagesController, :admin_tools
    get "/admin/permissions", LegacyPagesController, :admin_permissions
    get "/permissions", LegacyPagesController, :permissions
    get "/cron_upload", LegacyPagesController, :cron_upload
    get "/blotter/editor", LegacyPagesController, :blotter_editor
    get "/ip_ban/list", LegacyPagesController, :ip_ban_list
    get "/source_history/all/:page_num", LegacyPagesController, :source_history_all
    get "/source_history/:image_id", LegacyPagesController, :source_history_image
    get "/tag_history/all/:page_num", LegacyPagesController, :tag_history_all
    get "/tag_history/:image_id", LegacyPagesController, :tag_history_image
    get "/user", LegacyPagesController, :user
    get "/user_config", LegacyPagesController, :user_config
    get "/user/:name", LegacyPagesController, :user
    get "/pm/read/:pm_id", LegacyPagesController, :pm_read
    get "/user_admin", LegacyPagesController, :user_admin_root
    get "/user_admin/login", LegacyPagesController, :login
    get "/user_admin/create", LegacyPagesController, :create
    get "/user_admin/list", LegacyPagesController, :user_list
    get "/user_admin/logout", LegacyPagesController, :logout
    get "/wiki", LegacyPagesController, :wiki_root
    get "/wiki/:title/:action", LegacyPagesController, :wiki_action
    get "/wiki/:title", LegacyPagesController, :wiki_show
    get "/blotter/list", LegacyPagesController, :blotter_list
    get "/random/:path_search", LegacyPagesController, :random
    get "/random", LegacyPagesController, :random
    get "/random_image/:action/:search", LegacyPagesController, :random_image
    get "/random_image/:action", LegacyPagesController, :random_image
    get "/sitemap.xml", LegacyPagesController, :sitemap_xml
    get "/api/danbooru/find_posts", LegacyPagesController, :danbooru_find_posts_xml
    get "/api/danbooru/post/index.xml", LegacyPagesController, :danbooru_find_posts_xml
    get "/api/danbooru/find_posts/index.json", LegacyPagesController, :danbooru_find_posts
    get "/browser_search.xml", LegacyPagesController, :browser_search_xml
    get "/browser_search/:tag_search", LegacyPagesController, :browser_search_suggest
    get "/api/internal/autocomplete", LegacyPagesController, :autocomplete
  end

  scope "/", ShimmiePhoenixWeb do
    pipe_through :compat_mutation

    post "/comment/add", CommentController, :add
    post "/post/set", PostController, :set_info
    post "/tag_edit", PostController, :edit_tags
    post "/favourite/add/:image_id", FavoritesController, :add
    post "/favourite/remove/:image_id", FavoritesController, :remove
    post "/approve_image/:image_id", PostController, :approve
    post "/approve_image", PostController, :approve
    post "/disapprove_image/:image_id", PostController, :disapprove
    post "/disapprove_image", PostController, :disapprove
    post "/featured_image/set/:image_id", PostAdminController, :feature
    post "/featured_image/set", PostAdminController, :feature
    post "/regen_thumb/one/:image_id", PostAdminController, :regen_thumb
    post "/regen_thumb/one", PostAdminController, :regen_thumb
    post "/image/delete", PostAdminController, :delete_image
    post "/image/replace", PostAdminController, :replace_image
    post "/note/add_request", PostAdminController, :add_note_request
    post "/note/add_note", PostAdminController, :add_note
    post "/note/edit_note", PostAdminController, :edit_note
    post "/note/delete_note", PostAdminController, :delete_note
    post "/note/nuke_notes", PostAdminController, :nuke_notes
    post "/note/nuke_requests", PostAdminController, :nuke_requests
    post "/upload", LegacyPagesController, :upload_post
    post "/permissions/save", LegacyPagesController, :permissions_save
    post "/blotter/add", LegacyPagesController, :blotter_add
    post "/ip_ban/create", LegacyPagesController, :ip_ban_create
    post "/ip_ban/delete", LegacyPagesController, :ip_ban_delete
    post "/ip_ban/bulk", LegacyPagesController, :ip_ban_bulk
    post "/auto_tag/add", LegacyPagesController, :auto_tag_add
    post "/auto_tag/remove", LegacyPagesController, :auto_tag_remove
    post "/alias/add", LegacyPagesController, :alias_add
    post "/alias/remove", LegacyPagesController, :alias_remove
    post "/user_admin/login", LegacyPagesController, :login_post
    post "/user_admin/recover", LegacyPagesController, :recover
    post "/user_admin/create", LegacyPagesController, :create_post
    post "/user_admin/create_other", LegacyPagesController, :create_other
    post "/user_admin/change_name", LegacyPagesController, :change_name
    post "/user_admin/change_pass", LegacyPagesController, :change_pass
    post "/user_admin/change_email", LegacyPagesController, :change_email
    post "/user_admin/change_class", LegacyPagesController, :change_class
    post "/user_admin/delete_user", LegacyPagesController, :delete_user
    post "/biography", LegacyPagesController, :biography_save
    post "/pm/delete", LegacyPagesController, :pm_delete
    post "/pm/send", LegacyPagesController, :pm_send
    post "/wiki/:title/:action", LegacyPagesController, :wiki_action_post
  end

  if Application.compile_env(:shimmie_phx, :compat_health_enabled, false) do
    scope "/__compat", ShimmiePhoenixWeb do
      pipe_through :api

      get "/health", CompatController, :health
    end
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:shimmie_phx, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ShimmiePhoenixWeb.Telemetry
    end
  end

  scope "/", ShimmiePhoenixWeb do
    pipe_through :browser
    get "/*legacy_path", LegacyFallbackController, :show
  end
end
