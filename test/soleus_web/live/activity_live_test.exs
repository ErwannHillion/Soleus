defmodule SoleusWeb.ActivityLiveTest do
  use SoleusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Soleus.Repo
  alias Soleus.Training
  alias Soleus.Training.{Activity, Stream}

  defp activity(attrs \\ %{}) do
    base = %{
      source: "fit_import",
      sport: "run",
      name: "Fractionne",
      started_at: DateTime.utc_now() |> DateTime.truncate(:second),
      distance_m: 10_000.0,
      moving_time_s: 3000,
      avg_speed_ms: 3.3,
      avg_hr: 150
    }

    %Activity{}
    |> Activity.ingest_changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  defp with_series(activity) do
    series = %{
      t: Enum.to_list(0..600),
      distance_m: Enum.map(0..600, &(&1 * 3.3)),
      speed_ms: Enum.map(0..600, fn _ -> 3.3 end),
      hr: Enum.map(0..600, fn _ -> 150 end),
      lat: Enum.map(0..600, &(48.82 + &1 * 0.00001)),
      lon: Enum.map(0..600, &(2.33 + &1 * 0.00001))
    }

    %Stream{}
    |> Stream.changeset(%{activity_id: activity.id, series: series})
    |> Repo.insert!()

    activity
  end

  defp laps(activity, specs) do
    rows =
      specs
      |> Enum.with_index()
      |> Enum.map(fn {{intensity, distance, duration}, index} ->
        %{
          index: index,
          intensity: intensity,
          distance_m: distance * 1.0,
          duration_s: duration * 1.0,
          speed_ms: distance / duration,
          avg_hr: 150,
          avg_power: 250
        }
      end)

    Training.insert_laps(activity, rows)
    activity
  end

  describe "seance structuree" do
    test "resume les series et distingue les intensites", %{conn: conn} do
      act =
        activity()
        |> with_series()
        |> laps([
          {"warmup", 1000, 360},
          {"active", 400, 100},
          {"recovery", 140, 75},
          {"active", 400, 98},
          {"recovery", 130, 75},
          {"cooldown", 1000, 350}
        ])

      {:ok, _live, html} = live(conn, ~p"/seance/#{act.id}")

      assert html =~ "Seance structuree"
      # Le resume doit regrouper les deux series de quatre cents metres.
      assert html =~ "2 x 400 m"
      assert html =~ "echauffement"
      assert html =~ "recuperation"
    end
  end

  describe "seance ordinaire" do
    test "les tours automatiques au kilometre ne passent pas pour des series", %{conn: conn} do
      # Garmin marque les tours automatiques `interval`, qui serait tentant a
      # lire comme « serie ». Un footing ne doit pas s'afficher comme une
      # seance structuree.
      act =
        activity(%{name: "Footing"})
        |> with_series()
        |> laps([
          {"interval", 1000, 380},
          {"interval", 1000, 375},
          {"interval", 1000, 378}
        ])

      {:ok, _live, html} = live(conn, ~p"/seance/#{act.id}")

      assert html =~ "Tours"
      refute html =~ "Seance structuree"
      refute html =~ "x 1000 m"
    end
  end

  describe "liaison avec la carte" do
    test "les points de survol portent leur instant", %{conn: conn} do
      act = activity() |> with_series()

      {:ok, _live, html} = live(conn, ~p"/seance/#{act.id}")

      # Sans cet instant, la carte ne peut pas placer son curseur a l'endroit
      # survole sur le graphique. Les guillemets du JSON sont echappes par
      # HEEx puisqu'il voyage dans un attribut.
      assert html =~ ~r/&quot;t&quot;:\d+/
    end

    test "le trace porte l'instant de chaque point", %{conn: conn} do
      act = activity() |> with_series()

      {:ok, _live, html} = live(conn, ~p"/seance/#{act.id}")

      assert html =~ ~r/data-track="\[\[[\d.]+,[\d.]+,\d+\]/
    end
  end

  describe "details" do
    test "le panneau disparait quand la montre n'a rien enregistre", %{conn: conn} do
      act = activity() |> with_series()

      {:ok, _live, html} = live(conn, ~p"/seance/#{act.id}")

      # Un bloc de tirets n'apprend rien et prend la place d'autre chose.
      refute html =~ "oscillation verticale"
    end

    test "affiche les dynamiques de course quand elles existent", %{conn: conn} do
      act = activity() |> with_series()

      Training.update_metrics(act, %{
        avg_power: 250,
        normalized_power: 265,
        vertical_oscillation_mm: 95.1,
        stance_time_ms: 254.0,
        step_length_mm: 1073.1,
        aerobic_effect: 3.3
      })

      {:ok, _live, html} = live(conn, ~p"/seance/#{act.id}")

      assert html =~ "oscillation verticale"
      assert html =~ "temps de contact"
      assert html =~ "250 W"
      assert html =~ "effet d&#39;entrainement"
    end
  end
end
