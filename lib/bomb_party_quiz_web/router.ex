defmodule BombPartyQuizWeb.Router do
  use BombPartyQuizWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BombPartyQuizWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", BombPartyQuizWeb do
    pipe_through :browser

    live "/", InicioLive
    live "/sala/:codigo", SalaLive
    live "/sala/:codigo/jugar", JuegoLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", BombPartyQuizWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:bomb_party_quiz, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: BombPartyQuizWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
