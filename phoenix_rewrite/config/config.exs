# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :shimmie_phx,
  namespace: ShimmiePhoenix,
  ecto_repos: [ShimmiePhoenix.Repo],
  generators: [timestamp_type: :utc_datetime],
  compat_health_enabled: false,
  session_cookie_secure: false

# Configures the endpoint
config :shimmie_phx, ShimmiePhoenixWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ShimmiePhoenixWeb.ErrorHTML, json: ShimmiePhoenixWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ShimmiePhoenix.PubSub,
  live_view: [signing_salt: "RdSZNAGt"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.28.2",
  shimmie_phx: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  shimmie_phx: [
    args: ~w(
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# These are the actual legacy form/config field names, not only "password".
config :phoenix, :filter_parameters, [
  "password",
  "pass",
  "token",
  "secret",
  "captcha",
  "authorization",
  "cookie",
  "privkey",
  "api_key"
]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
