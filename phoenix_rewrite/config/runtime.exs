import Config

app_root = Path.expand("..", __DIR__)
legacy_root = System.get_env("SHIMMIE_LEGACY_ROOT") || Path.expand("..", app_root)
legacy_assets_dir = System.get_env("SHIMMIE_ASSETS_DIR") || Path.join(legacy_root, "assets")

legacy_config_path =
  System.get_env("SHIMMIE_LEGACY_CONFIG_PATH") ||
    Path.join([legacy_root, "data", "config", "shimmie.conf.php"])

dsn_to_ecto_url = fn dsn ->
  case String.split(dsn, ":", parts: 2) do
    ["pgsql", kv] ->
      params =
        kv
        |> String.split(";", trim: true)
        |> Enum.reduce(%{}, fn part, acc ->
          case String.split(part, "=", parts: 2) do
            [k, v] -> Map.put(acc, k, v)
            _ -> acc
          end
        end)

      user = Map.get(params, "user", "postgres")
      pass = Map.get(params, "password", "")
      host = Map.get(params, "host", "localhost")
      port = Map.get(params, "port")
      db = Map.get(params, "dbname", "shimmie")

      userinfo =
        if pass == "" do
          user
        else
          "#{user}:#{pass}"
        end

      hostinfo =
        if is_nil(port) || port == "" do
          host
        else
          "#{host}:#{port}"
        end

      "ecto://#{userinfo}@#{hostinfo}/#{db}"

    _ ->
      nil
  end
end

legacy_dsn =
  cond do
    System.get_env("SHIMMIE_LEGACY_DSN") ->
      System.get_env("SHIMMIE_LEGACY_DSN")

    File.exists?(legacy_config_path) ->
      case File.read(legacy_config_path) do
        {:ok, content} ->
          case Regex.run(~r/define\(\s*['"]DATABASE_DSN['"]\s*,\s*['"]([^'"]+)['"]\s*\)/, content) do
            [_, dsn] -> dsn
            _ -> nil
          end

        _ ->
          nil
      end

    true ->
      nil
  end

resolved_database_url =
  System.get_env("SHIMMIE_DATABASE_URL") || if(legacy_dsn, do: dsn_to_ecto_url.(legacy_dsn))

config :shimmie_phx,
  legacy_root: legacy_root,
  legacy_assets_dir: legacy_assets_dir,
  legacy_config_path: legacy_config_path

if config_env() == :dev and resolved_database_url do
  config :shimmie_phx, ShimmiePhoenix.Repo, url: resolved_database_url
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/shimmie_phx start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :shimmie_phx, ShimmiePhoenixWeb.Endpoint, server: true
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") || resolved_database_url ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :shimmie_phx, ShimmiePhoenix.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :shimmie_phx, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :shimmie_phx, ShimmiePhoenixWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Bind Phoenix to loopback only; public traffic should enter through the
      # reverse proxy.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {127, 0, 0, 1},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :shimmie_phx, ShimmiePhoenixWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :shimmie_phx, ShimmiePhoenixWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
