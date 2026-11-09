defmodule Soleus.WellnessRecordsTest do
  use ExUnit.Case, async: true

  alias Soleus.Ingest.Wellness
  alias Soleus.Training

  describe "records/1" do
    test "accepte une liste d'enregistrements" do
      assert Wellness.records([%{"calendarDate" => "2026-11-01"}]) == [
               %{"calendarDate" => "2026-11-01"}
             ]
    end

    test "accepte un enregistrement seul" do
      assert Wellness.records(%{"calendarDate" => "2026-11-01"}) == [
               %{"calendarDate" => "2026-11-01"}
             ]
    end

    test "deballe un objet qui enveloppe une liste" do
      # Les reponses de l'API ne sont pas toutes de la meme forme, et la cle
      # d'enveloppe varie. On la cherche plutot que de la supposer.
      body = %{"dailySummaries" => [%{"calendarDate" => "2026-11-01"}]}
      assert Wellness.records(body) == [%{"calendarDate" => "2026-11-01"}]
    end

    test "rend une liste vide sur ce qui n'est pas exploitable" do
      assert Wellness.records(nil) == []
      assert Wellness.records("texte") == []
      assert Wellness.records(%{"erreur" => "rien"}) == []
    end
  end

  describe "merge_records/3" do
    test "fusionne plusieurs familles sur la meme journee" do
      days =
        %{}
        |> Wellness.merge_records(:daily_summary, [
          %{"calendarDate" => "2026-11-01", "restingHeartRate" => 52, "totalSteps" => 8000}
        ])
        |> Wellness.merge_records(:sleep, [
          %{"calendarDate" => "2026-11-01", "deepSleepSeconds" => 3600}
        ])

      day = days[~D[2026-11-01]]

      assert day.resting_hr == 52
      assert day.steps == 8000
      assert day.sleep_deep_s == 3600
    end

    test "ignore un enregistrement sans date plutot que d'echouer" do
      # Un export couvre plus d'un an et plusieurs modeles de montre ; un
      # enregistrement exotique ne doit pas faire perdre les autres.
      assert Wellness.merge_records(%{}, :sleep, [%{"deepSleepSeconds" => 100}]) == %{}
    end
  end

  describe "zone_seconds/1" do
    test "convertit les millisecondes et replie la zone au dela de la cinq" do
      summary =
        0..6
        |> Enum.map(&{"hrTimeInZone_#{&1}", (&1 + 1) * 1000.0})
        |> Map.new()

      assert Training.zone_seconds(summary) == [1, 2, 3, 4, 5, 13]
    end

    test "rend nil quand aucune zone n'est fournie" do
      assert Training.zone_seconds(%{"activityName" => "Footing"}) == nil
    end
  end
end
