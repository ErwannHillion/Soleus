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

    test "n'affiche que les graphiques dont la serie existe", %{conn: conn} do
      # Une montre d'entree de gamme n'enregistre ni puissance ni dynamiques
      # de course. Un graphique vide ne dirait rien et prendrait la place.
      act = activity() |> with_series()

      {:ok, _live, html} = live(conn, ~p"/seance/#{act.id}")

      assert html =~ "Allure"
      assert html =~ "Frequence cardiaque"
      refute html =~ "Longueur de foulee"
      refute html =~ "Temps de contact au sol"
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

    test "l'allure corrigee de la pente apparait quand Garmin la fournit", %{conn: conn} do
      act = activity() |> with_series()
      Training.update_metrics(act, %{grade_adjusted_speed_ms: 3.4})

      {:ok, _live, html} = live(conn, ~p"/seance/#{act.id}")

      assert html =~ "allure corrigee"
    end
  end

  describe "allure corrigee de la pente" do
    test "est ignoree quand Garmin n'a pas de donnee d'altitude" do
      # Sans altimetre actif, Garmin renseigne quand meme le champ avec une
      # valeur sans signification : sur l'historique reel, des corrections de
      # trente pour cent sur du plat.
      act = activity()

      Training.apply_summary(act.id, %{
        "avgSpeed" => 0.283,
        "avgGradeAdjustedSpeed" => 0.1875,
        "elevationGain" => 0.0
      })

      assert Repo.get!(Activity, act.id).grade_adjusted_speed_ms == nil
    end

    test "est retenue quand le denivele existe et que le rapport est plausible" do
      act = activity()

      Training.apply_summary(act.id, %{
        "avgSpeed" => 0.283,
        "avgGradeAdjustedSpeed" => 0.2855,
        "elevationGain" => 4761.0
      })

      corrigee = Repo.get!(Activity, act.id).grade_adjusted_speed_ms

      # Le rapport, sans unite, s'applique a la vitesse du fichier FIT. Le
      # resume n'emploie pas la meme echelle que le FIT, donc reprendre sa
      # valeur telle quelle donnerait une allure dix fois trop lente.
      assert_in_delta corrigee, 3.3 * (0.2855 / 0.283), 0.001
    end
  end
end
