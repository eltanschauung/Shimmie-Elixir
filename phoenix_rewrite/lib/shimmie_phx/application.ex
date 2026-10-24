defmodule ShimmiePhoenix.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ShimmiePhoenix.Cache,
      ShimmiePhoenix.AuthThrottle,
      ShimmiePhoenix.WorkGate,
      {Task.Supervisor, name: ShimmiePhoenix.ExternalSupervisor, max_children: 2},
      {Task.Supervisor, name: ShimmiePhoenix.NotificationSupervisor, max_children: 16},
      ShimmiePhoenixWeb.Telemetry,
      ShimmiePhoenix.Repo,
      {DNSCluster, query: Application.get_env(:shimmie_phx, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ShimmiePhoenix.PubSub},
      # Start a worker by calling: ShimmiePhoenix.Worker.start_link(arg)
      # {ShimmiePhoenix.Worker, arg},
      # Start to serve requests, typically the last entry
      ShimmiePhoenixWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ShimmiePhoenix.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ShimmiePhoenixWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
