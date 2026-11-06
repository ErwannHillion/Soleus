defmodule SoleusWeb.PlanLiveTest do
  use SoleusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Soleus.Analytics.ModelFit
  alias Soleus.Repo

  # La faisabilite part du dernier ajustement : sans lui, toute evaluation
  # rend « pas assez de donnees », ce qui est correct mais ne teste rien.
  setup do
    Repo.insert!(%ModelFit{
      fitted_on: Date.utc_today(),
      sport: "run",
      window_days: 90,
      cs_ms: 3.2,
      d_prime_m: 140.0,
      r2: 0.99,
      sample_count: 8,
      vdot: 37.4,
      endurance_exponent: 1.06,
      exponent_source: "literature",
      predictions: %{"10000" => 3180.0}
    })

    :ok
  end

  defp set(live, overrides) do
    defaults = %{
      "date" => Date.utc_today() |> Date.add(84) |> Date.to_iso8601(),
      "distance" => "10000",
      "elevation" => "0",
      "target" => ""
    }

    render_change(live, "change", Map.merge(defaults, overrides))
  end

  test "sans temps cible, propose un objectif deduit de la forme", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/plan")

    html = set(live, %{})

    assert html =~ "Objectif retenu" or html =~ "OBJECTIF RETENU" or html =~ "objectif retenu"
    refute html =~ "incomprehensible"
  end

  test "un objectif hors de portee est annonce comme tel, avec le repli", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/plan")

    # Trois minutes sur dix kilometres : impossible pour quiconque.
    html = set(live, %{"target" => "3:00"})

    assert html =~ "Hors de portee"
    # Le plan ne doit pas disparaitre : il vise alors ce qui est atteignable.
    assert html =~ "Les seances"
  end

  test "un temps cible illisible le dit, sans casser la page", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/plan")

    html = set(live, %{"target" => "tres vite"})

    assert html =~ "incomprehensible"
  end

  test "le denivele est converti en distance equivalente", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/plan")

    html = set(live, %{"elevation" => "300"})

    assert html =~ "300 m de denivele"
    assert html =~ "13.0 km"
  end

  test "une date passee ne produit pas de plan", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/plan")

    html = set(live, %{"date" => Date.utc_today() |> Date.add(-7) |> Date.to_iso8601()})

    refute html =~ "Les seances"
  end
end
