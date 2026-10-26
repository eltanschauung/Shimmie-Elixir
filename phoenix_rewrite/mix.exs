defmodule ShimmiePhoenix.MixProject do
  use Mix.Project

  def project do
    [
      app: :shimmie_phx,
      version: "0.1.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {ShimmiePhoenix.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets, :ssl]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.16"},
      {:phoenix_ecto, "~> 4.7.0"},
      {:ecto_sql, "~> 3.14.0"},
      {:postgrex, "~> 0.22.4"},
      {:phoenix_html, "~> 4.3.0"},
      {:phoenix_live_reload, "~> 1.7.0", only: :dev},
      {:phoenix_live_view, "~> 1.2.13"},
      {:floki, "~> 0.38.4", only: :test},
      {:phoenix_live_dashboard, "~> 0.9.1"},
      {:esbuild, "~> 0.10.1", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5.2", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.2.0"},
      {:telemetry_poller, "~> 1.3.0"},
      {:gettext, "~> 1.0.2"},
      {:jason, "~> 1.4.5"},
      {:dns_cluster, "~> 0.3.1"},
      {:bandit, "~> 1.14.0"},
      {:plug, "~> 1.20.3"},
      {:bcrypt_elixir, "~> 3.3.2"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind shimmie_phx", "esbuild shimmie_phx"],
      "assets.deploy": [
        "tailwind shimmie_phx --minify",
        "esbuild shimmie_phx --minify",
        "phx.digest"
      ]
    ]
  end
end
