defmodule Soleus.HealthTest do
  use ExUnit.Case, async: true

  alias Soleus.Health
  alias Soleus.Health.DailyWellness

  describe "situate/3" do
    test "situe une valeur par rapport a sa fourchette personnelle" do
      assert DailyWellness.situate(78, 61, 104) == :in_range
      assert DailyWellness.situate(55, 61, 104) == :low
      assert DailyWellness.situate(120, 61, 104) == :high
    end

    test "rend :unknown plutot que de deviner quand une borne manque" do
      # Une mesure sans sa ligne de base n'est pas interpretable : la meme
      # frequence au repos est excellente chez l'un et preoccupante chez
      # l'autre. Mieux vaut ne rien dire que d'appliquer un seuil general.
      assert DailyWellness.situate(78, nil, 104) == :unknown
      assert DailyWellness.situate(nil, 61, 104) == :unknown
      assert DailyWellness.situate(78, 104, 61) == :unknown
    end
  end

  describe "position/3" do
    test "place la valeur dans sa fourchette" do
      assert DailyWellness.position(61, 61, 104) == 0.0
      assert DailyWellness.position(104, 61, 104) == 1.0
      assert_in_delta DailyWellness.position(82.5, 61, 104), 0.5, 0.001
    end

    test "borne les valeurs hors fourchette pour qu'elles restent visibles" do
      assert DailyWellness.position(0, 61, 104) == -0.15
      assert DailyWellness.position(500, 61, 104) == 1.15
    end
  end

  describe "systems/1" do
    test "rend une liste vide sans donnee" do
      assert Health.systems(nil) == []
    end

    test "derive l'etat de chaque systeme et remplit les regions" do
      systems =
        Health.systems(%{
          resting_hr: 50,
          hr_baseline_low: 50,
          hr_baseline_high: 69,
          hrv_overnight: 78.0,
          hrv_baseline_low: 61.0,
          hrv_baseline_high: 104.0,
          sleep_score: 81,
          sleep_total_s: 29_100,
          stress_avg: 16,
          garmin_acwr: 0.9
        })

      by_key = Map.new(systems, &{&1.key, &1})

      assert by_key[:heart].status == :in_range
      assert by_key[:hrv].status == :in_range
      assert by_key[:sleep].status == :in_range
      assert by_key[:sleep].detail == "8 h 05"
      assert by_key[:load].status == :in_range

      # Une mesure absente ne doit pas inventer un etat.
      assert by_key[:vo2max].status == :unknown
      assert by_key[:vo2max].value == "—"
    end

    test "signale une charge aigue trop haute" do
      systems = Health.systems(%{garmin_acwr: 1.8})
      assert Enum.find(systems, &(&1.key == :load)).status == :high
    end
  end
end
