# Historique d'entrainement de demonstration.
#
# Sert a deux choses : exercer la chaine complete (ingestion, metriques,
# ajustement, projection) sans attendre un export Garmin, et donner au tableau
# de bord de quoi s'afficher au premier lancement.
#
#     mix run priv/repo/seeds_demo.exs
#
# Les seances sont construites a partir d'une vitesse critique qui progresse
# lentement sur la periode, et non tirees au hasard : c'est cette progression
# que les modeles doivent retrouver. Si la vitesse critique ajustee a la fin ne
# ressemble pas a celle injectee au depart, c'est le moteur qui a tort.

alias Soleus.Repo
alias Soleus.Training
alias Soleus.Training.{Activity, Stream}

# Graine fixe : deux executions produisent le meme historique, ce qui rend les
# resultats comparables d'un lancement a l'autre.
:rand.seed(:exsss, {20_261_105, 42, 7})

days = 182
sample_interval = 4

# Vitesse critique injectee : de 3.18 m/s (5:14/km) a 3.44 m/s (4:51/km) sur
# six mois, soit une progression soutenue mais credible.
cs_start = 3.18
cs_end = 3.44

hr_rest = 48
hr_max = 191

# Semaine type. `nil` est un jour de repos.
week = %{
  1 => :easy,
  2 => :intervals,
  3 => :easy,
  4 => :tempo,
  5 => nil,
  6 => :long,
  7 => :easy
}

names = %{
  easy: "Footing",
  long: "Sortie longue",
  tempo: "Seuil",
  intervals: "Fractionne",
  test: "Test 5000 m"
}

# Chaque seance est une liste de blocs {duree_s, intensite}, ou l'intensite est
# un multiple de la vitesse critique du jour.
blocks = fn
  :easy ->
    [{2400 + :rand.uniform(1200), 0.72}]

  :long ->
    [{4800 + :rand.uniform(1800), 0.75}]

  :tempo ->
    [{900, 0.70}, {900, 0.99}, {180, 0.68}, {900, 0.99}, {600, 0.66}]

  :intervals ->
    [{1200, 0.70}] ++ List.flatten(List.duplicate([{180, 1.10}, {120, 0.60}], 5)) ++ [{600, 0.66}]

  :test ->
    [{1200, 0.72}, {1370, 1.03}, {600, 0.65}]
end

cs_on = fn day -> cs_start + (cs_end - cs_start) * day / days end

# Vitesse instantanee : l'intensite nominale, moins une derive de fatigue qui
# s'installe avec la duree, plus un bruit de foulee.
speed_at = fn cs, intensity, elapsed, total ->
  fatigue = 1.0 - 0.025 * (elapsed / max(total, 1))
  noise = 1.0 + (:rand.uniform() - 0.5) * 0.04
  cs * intensity * fatigue * noise
end

# Frequence cardiaque : fonction de l'intensite, avec une derive cardiaque
# lente, et l'inertie approximee en lissant vers le point precedent.
hr_at = fn speed, cs, elapsed, previous ->
  ratio = speed / cs
  # Calee pour qu'a la vitesse critique (ratio 1.0) la FC tombe vers 88 % de
  # la FC max, et vers 70 % en footing : ce sont les reperes physiologiques
  # usuels, et le moteur de charge en depend.
  target = hr_rest + (hr_max - hr_rest) * min(0.99, 0.84 * :math.pow(ratio, 1.025))
  raw = target * (1.0 + 0.00002 * elapsed) + (:rand.uniform() - 0.5) * 3
  smoothed = if previous, do: previous + (raw - previous) * 0.08, else: raw

  smoothed |> min(hr_max) |> max(hr_rest) |> round()
end

build_series = fn cs, session_blocks ->
  total = session_blocks |> Enum.map(&elem(&1, 0)) |> Enum.sum()

  intensities =
    Enum.flat_map(session_blocks, fn {duration, intensity} ->
      List.duplicate(intensity, div(duration, sample_interval))
    end)

  {points, _acc} =
    intensities
    |> Enum.with_index()
    |> Enum.map_reduce({0.0, nil}, fn {intensity, i}, {distance, previous_hr} ->
      elapsed = i * sample_interval
      speed = speed_at.(cs, intensity, elapsed, total)
      hr = hr_at.(speed, cs, elapsed, previous_hr)

      {{elapsed, distance, speed, hr}, {distance + speed * sample_interval, hr}}
    end)

  %{
    t: Enum.map(points, &elem(&1, 0)),
    distance_m: Enum.map(points, &elem(&1, 1)),
    speed_ms: Enum.map(points, &elem(&1, 2)),
    hr: Enum.map(points, &elem(&1, 3))
  }
end

today = Date.utc_today()
start_date = Date.add(today, -days)

IO.puts("Generation de #{days} jours d'historique...")

inserted =
  Enum.reduce(0..days, 0, fn offset, count ->
    date = Date.add(start_date, offset)

    # Un test chronometre toutes les six semaines : c'est ce qui ancre le haut
    # de la courbe vitesse-duree, sans quoi la vitesse critique s'ajusterait
    # sur des seances trop homogenes.
    kind =
      if rem(offset, 42) == 20 do
        :test
      else
        Map.get(week, Date.day_of_week(date))
      end

    if is_nil(kind) do
      count
    else
      cs = cs_on.(offset)
      series = build_series.(cs, blocks.(kind))

      distance = List.last(series.distance_m)
      elapsed = List.last(series.t)
      hrs = series.hr

      started_at = DateTime.new!(date, ~T[12:15:00], "Etc/UTC") |> DateTime.truncate(:second)

      attrs = %{
        source: "manual",
        sport: "run",
        name: Map.get(names, kind),
        started_at: started_at,
        distance_m: distance,
        moving_time_s: elapsed,
        elapsed_time_s: elapsed,
        elevation_gain_m: 10.0 + :rand.uniform(60) * 1.0,
        avg_hr: round(Enum.sum(hrs) / length(hrs)),
        max_hr: Enum.max(hrs),
        avg_cadence: 80.0 + :rand.uniform() * 4,
        avg_speed_ms: distance / elapsed,
        max_speed_ms: Enum.max(series.speed_ms),
        calories: round(distance / 1000 * 68)
      }

      {:ok, activity} = %Activity{} |> Activity.ingest_changeset(attrs) |> Repo.insert()

      {:ok, _stream} =
        %Stream{}
        |> Stream.changeset(%{activity_id: activity.id, series: series})
        |> Repo.insert()

      Training.insert_best_efforts(activity, series)

      count + 1
    end
  end)

IO.puts("#{inserted} seances inserees.")
