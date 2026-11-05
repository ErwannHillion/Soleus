defmodule Soleus.MeanMaximalTest do
  use ExUnit.Case, async: true

  alias Soleus.Analytics.MeanMaximal, as: MM

  defp constant(speed, duration, step \\ 1) do
    times = Enum.take_every(0..duration, step)

    %{
      t: times,
      distance_m: Enum.map(times, &(&1 * speed * 1.0)),
      hr: Enum.map(times, fn _ -> 150 end)
    }
  end

  describe "by_duration/1" do
    test "retrouve exactement une allure constante" do
      effort = constant(4.0, 600) |> MM.grid() |> MM.by_duration() |> Enum.find(&(&1.duration_s == 60))

      assert_in_delta effort.speed_ms, 4.0, 0.001
    end

    test "isole une pointe plus courte que la fenetre" do
      speeds = fn s -> if s >= 200 and s < 300, do: 6.0, else: 4.0 end
      {dists, _} = Enum.map_reduce(0..600, 0.0, fn s, acc -> {acc, acc + speeds.(s)} end)

      efforts = %{t: Enum.to_list(0..600), distance_m: dists} |> MM.grid() |> MM.by_duration()
      by = Map.new(efforts, &{&1.duration_s, &1.speed_ms})

      # La pointe dure 100 s : elle remplit les fenetres courtes, et se dilue
      # proportionnellement dans les plus longues.
      assert_in_delta by[60], 6.0, 0.01
      assert_in_delta by[120], (100 * 6.0 + 20 * 4.0) / 120, 0.01
      assert_in_delta by[300], (100 * 6.0 + 200 * 4.0) / 300, 0.01
    end

    test "ne compte aucune distance pendant une pause" do
      # Montre en pause de 100 s a 220 s : l'interpolation naive placerait
      # l'athlete a mi-chemin, et fabriquerait un record qui n'a pas eu lieu.
      grid = MM.grid(%{t: [0, 100, 220, 320], distance_m: [0.0, 400.0, 400.0, 800.0]})

      assert elem(grid.distance, 160) == 400.0
    end
  end

  describe "by_distance/1" do
    test "chronometre une distance a allure constante" do
      effort = constant(4.0, 600) |> MM.grid() |> MM.by_distance() |> Enum.find(&(&1.distance_m == 1000.0))

      assert effort.duration_s == 250
    end
  end

  describe "frequence cardiaque" do
    test "moyenne la FC sur la fenetre, sans la diluer" do
      effort = constant(4.0, 600) |> MM.grid() |> MM.by_duration() |> Enum.find(&(&1.duration_s == 60))

      assert effort.avg_hr == 150
    end

    test "reste juste quand la serie est echantillonnee plus lentement que 1 Hz" do
      # L'enregistrement intelligent de Garmin espace les points. Les secondes
      # sans mesure doivent etre interpolees et non comptees comme des zeros,
      # sinon la FC moyenne se divise par le pas d'echantillonnage.
      effort =
        constant(4.0, 600, 4) |> MM.grid() |> MM.by_duration() |> Enum.find(&(&1.duration_s == 60))

      assert effort.avg_hr == 150
    end
  end
end
