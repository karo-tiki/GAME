defmodule BombPartyQuiz.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BombPartyQuizWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:bomb_party_quiz, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: BombPartyQuiz.PubSub},
      # Registry para encontrar el proceso de una sala a partir de su código
      {Registry, keys: :unique, name: BombPartyQuiz.SalaRegistry},
      # Supervisor dinámico: arranca/destruye procesos Sala según se crean/terminan partidas
      {DynamicSupervisor, strategy: :one_for_one, name: BombPartyQuiz.SalaSupervisor},
      # Start to serve requests, typically the last entry
      BombPartyQuizWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: BombPartyQuiz.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BombPartyQuizWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
