defmodule SoleusWeb.PageController do
  use SoleusWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
