defmodule Soleus.CoachingPlanTest do
  use Soleus.DataCase, async: false

  alias Soleus.Coaching.{Feasibility, Plan}

  describe "build/1" do
    test "produit les quatre phases dans l'ordre" do
      phases = Plan.build(%{weeks: 12}) |> Map.get(:weeks) |> Enum.map(& &1.phase)

      assert hd(phases) == :base
      assert List.last(phases) == :taper
      # Les phases ne doivent jamais revenir en arriere : une semaine de base
      # apres un bloc specifique n'aurait aucun sens.
      ordre = [:base, :build, :peak, :taper]
      rangs = Enum.map(phases, &Enum.find_index(ordre, fn p -> p == &1 end))
      assert rangs == Enum.sort(rangs)
    end

    test "une preparation courte saute la base plutot que de la diluer" do
      phases = Plan.build(%{weeks: 5}) |> Map.get(:weeks) |> Enum.map(& &1.phase)

      refute :base in phases
      assert :taper in phases
      assert length(phases) == 5
    end

    test "la charge ne double jamais sur un cycle" do
      plan = Plan.build(%{weeks: 20})

      # Composer dix pour cent par semaine sur vingt semaines multiplierait la
      # charge par sept. Le plafond de cycle est ce qui empeche le plan de
      # devenir une ordonnance de blessure.
      assert plan.peak_weekly_load <= plan.start_weekly_load * 2.0 + 0.001
    end

    test "l'affutage reduit la charge des dernieres semaines" do
      weeks = Plan.build(%{weeks: 12}).weeks
      taper = Enum.filter(weeks, &(&1.phase == :taper))
      peak = weeks |> Enum.map(& &1.target_load) |> Enum.max()

      assert taper != []
      assert Enum.all?(taper, &(&1.target_load < peak))
    end

    test "chaque seance a une duree utilisable" do
      for week <- Plan.build(%{weeks: 12}).weeks, session <- week.sessions do
        assert session.duration_s >= 600, "seance trop courte : #{inspect(session)}"
        assert session.structure =~ "min"
      end
    end

    test "respecte le rythme de seances, sans descendre sous trois" do
      plan = Plan.build(%{weeks: 10})

      assert plan.frequency >= 3
      assert plan.frequency <= 6
      assert Enum.all?(plan.weeks, &(length(&1.sessions) <= plan.frequency))
    end
  end

  describe "required_cs/4" do
    test "inverse exactement la prediction sous vingt minutes" do
      # d = cs * t + d'  =>  cs = (d - d') / t
      assert_in_delta Feasibility.required_cs(3000, 900, 140, 1.06), (3000 - 140) / 900, 0.0001
    end

    test "inverse la relation de Riegel au dela" do
      cs = 3.2
      d_prime = 140.0
      exponent = 1.06

      # On part d'une vitesse critique connue, on en deduit un temps par la
      # meme cascade que l'application, puis on verifie que l'inversion
      # retrouve la vitesse de depart.
      anchor = cs * 1200 + d_prime
      time = 1200 * :math.pow(21_097.5 / anchor, exponent)

      assert_in_delta Feasibility.required_cs(21_097.5, time, d_prime, exponent), cs, 0.001
    end
  end
end
