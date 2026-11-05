defmodule SoleusWeb.SyncButtonTest do
  use SoleusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Soleus.Sync

  describe "bouton de synchronisation Garmin" do
    test "affiche l'etat au chargement", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "phx-click=\"sync\""
      assert html =~ "Garmin"
    end

    test "sans cle configuree, explique quoi faire plutot que d'echouer", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/")

      html = live |> element("button[phx-click='sync']") |> render_click()

      # Le message doit dire ou creer la cle : un simple « erreur » laisserait
      # l'athlete sans recours.
      assert html =~ "connect.garmin.com"
    end

    test "le declenchement ne programme rien sans cle" do
      assert Sync.trigger() == {:error, :no_api_key}
      refute Sync.running?()
    end
  end

  describe "evenements de progression" do
    test "la vue suit l'avancement diffuse par le job", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/")

      Sync.broadcast({:sync, :progress, %{index: 3, total: 7}})
      assert render(live) =~ "3 / 7"

      Sync.broadcast({:sync, :done, %{imported: 2, seen: 7}})
      assert render(live) =~ "2 nouvelle(s)"
    end

    test "une synchronisation sans nouveaute le dit, au lieu de rester muette", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/")

      Sync.broadcast({:sync, :done, %{imported: 0, seen: 4}})
      assert render(live) =~ "deja a jour"
    end
  end
end
