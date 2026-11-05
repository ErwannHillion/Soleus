defmodule Soleus.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SoleusWeb.Telemetry,
      Soleus.Repo,
      {DNSCluster, query: Application.get_env(:soleus, :dns_cluster_query) || :ignore},
      {Oban, Application.fetch_env!(:soleus, Oban)},
      Soleus.Ingest.Garmin.Token,
      {Phoenix.PubSub, name: Soleus.PubSub},
      # Start a worker by calling: Soleus.Worker.start_link(arg)
      # {Soleus.Worker, arg},
      # Start to serve requests, typically the last entry
      SoleusWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Soleus.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Rattrapage au demarrage : le cron de minuit ne se declenche que si
        # l'application tourne a cet instant, ce qui n'arrive presque jamais
        # sur un poste qu'on eteint. Voir `Soleus.Sync`.
        Soleus.Sync.schedule_boot_catch_up()
        {:ok, pid}

      error ->
        error
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SoleusWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
