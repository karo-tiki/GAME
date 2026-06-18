defmodule BombPartyQuizWeb.PageController do
  use BombPartyQuizWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
