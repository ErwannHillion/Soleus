defmodule Soleus.Analytics.MeanMaximal do
  @moduledoc """
  Courbe des meilleurs efforts d'une activite.

  Deux questions symetriques, calculees sur la meme grille :

    * la plus grande vitesse moyenne tenue pendant N secondes -> la courbe
      vitesse-duree, entree du modele de vitesse critique ;
    * le temps le plus court sur N metres -> les records personnels lisibles.

  Tout passe d'abord par une grille a 1 Hz. Les fichiers Garmin ne sont pas
  regulierement echantillonnes : l'enregistrement intelligent espace les
  points quand rien ne change, et une pause laisse un trou. Sans rendre l'axe
  du temps regulier, une fenetre de "60 secondes" compterait un nombre
  variable de points et les comparaisons seraient fausses.
  """

  alias Soleus.Analytics.Pace

  # Paliers de duree, resserres en bas : c'est la ou la courbe vitesse-duree
  # est la plus informative pour separer vitesse pure et endurance.
  @durations [
    5,
    10,
    15,
    20,
    30,
    45,
    60,
    90,
    120,
    180,
    240,
    300,
    420,
    600,
    900,
    1200,
    1800,
    2700,
    3600,
    5400,
    7200
  ]

  # Distances de course, de la ligne droite au marathon.
  @distances [
    400.0,
    800.0,
    1000.0,
    1609.34,
    3000.0,
    5000.0,
    10_000.0,
    15_000.0,
    21_097.5,
    42_195.0
  ]

  # Au dela de cet ecart entre deux points, on considere que la montre etait
  # en pause et non que l'athlete a couru sans etre enregistre. La distance
  # est alors gelee sur l'intervalle. C'est volontairement le choix pessimiste
  # : une fenetre qui chevauche une pause devient lente et ne gagnera jamais,
  # la ou une interpolation inventerait un record.
  @pause_gap_s 30

  @type grid :: %{size: non_neg_integer(), distance: tuple(), hr_prefix: tuple() | nil}

  @doc "Les paliers de duree utilises par `durations/1`."
  def durations, do: @durations

  @doc "Les distances de course utilisees par `distances/1`."
  def distances, do: @distances

  @doc """
  Construit la grille a 1 Hz : distance cumulee a chaque seconde, et sommes
  prefixes de frequence cardiaque pour obtenir la FC moyenne d'une fenetre en
  temps constant.
  """
  @spec grid(map()) :: grid() | nil
  def grid(series) do
    with times when is_list(times) <- series[:t],
         dists when is_list(dists) <- series[:distance_m],
         samples = paired(times, dists),
         [_, _ | _] <- samples do
      {last_t, _} = List.last(samples)
      size = trunc(last_t) + 1

      %{
        size: size,
        distance: resample(samples, size),
        hr_prefix: hr_prefix(times, series[:hr], size)
      }
    else
      _ -> nil
    end
  end

  @doc """
  Meilleure vitesse moyenne pour chaque palier de duree tenant dans l'activite.

  Rend une liste de `%{duration_s:, distance_m:, speed_ms:, avg_hr:}`.
  """
  @spec by_duration(grid() | nil) :: [map()]
  def by_duration(nil), do: []

  def by_duration(grid) do
    @durations
    |> Enum.filter(&(&1 < grid.size))
    |> Enum.map(&best_window(grid, &1))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Temps le plus court pour chaque distance de course couverte par l'activite.

  Rend une liste de `%{duration_s:, distance_m:, speed_ms:, avg_hr:}`.
  """
  @spec by_distance(grid() | nil) :: [map()]
  def by_distance(nil), do: []

  def by_distance(grid) do
    total = elem(grid.distance, grid.size - 1)

    @distances
    |> Enum.filter(&(&1 <= total))
    |> Enum.map(&fastest_for(grid, &1))
    |> Enum.reject(&is_nil/1)
  end

  # -- fenetre glissante a duree fixe ----------------------------------------

  # La grille etant reguliere, chaque fenetre de `duration` secondes se lit en
  # deux acces : la distance se soustrait, elle n'a pas a etre resommee.
  defp best_window(grid, duration) do
    last_start = grid.size - 1 - duration

    {best_dist, best_start} =
      Enum.reduce(0..last_start, {-1.0, 0}, fn start, {max_d, _max_i} = acc ->
        covered = elem(grid.distance, start + duration) - elem(grid.distance, start)
        if covered > max_d, do: {covered, start}, else: acc
      end)

    if best_dist > 0 do
      %{
        duration_s: duration,
        distance_m: best_dist,
        speed_ms: best_dist / duration,
        avg_hr: window_hr(grid, best_start, duration)
      }
    end
  end

  # -- fenetre glissante a distance fixe -------------------------------------

  # Deux pointeurs : la distance cumulee etant croissante, avancer le debut ne
  # peut que rapprocher la fin. Chaque indice n'est visite qu'une fois, donc
  # un seul passage sur la grille suffit pour une distance donnee.
  defp fastest_for(grid, target) do
    case scan_distance(grid, target) do
      nil ->
        nil

      {duration, start} ->
        %{
          duration_s: duration,
          distance_m: target,
          speed_ms: target / duration,
          avg_hr: window_hr(grid, start, duration)
        }
    end
  end

  defp scan_distance(grid, target) do
    Enum.reduce(0..(grid.size - 1), {0, nil}, fn finish, {start, best} ->
      start = advance(grid, start, finish, target)

      {start, keep_shortest(grid, start, finish, target, best)}
    end)
    |> elem(1)
  end

  defp keep_shortest(grid, start, finish, target, best) do
    covered = elem(grid.distance, finish) - elem(grid.distance, start)

    cond do
      covered < target -> best
      best == nil -> {finish - start, start}
      finish - start < elem(best, 0) -> {finish - start, start}
      true -> best
    end
  end

  # Fait glisser le debut de fenetre tant que la distance cible reste couverte,
  # pour garder la fenetre la plus courte possible.
  defp advance(grid, start, finish, target) do
    if start < finish and
         elem(grid.distance, finish) - elem(grid.distance, start + 1) >= target do
      advance(grid, start + 1, finish, target)
    else
      start
    end
  end

  # -- grille -----------------------------------------------------------------

  defp paired(times, values) do
    Enum.zip(times, values)
    |> Enum.reject(fn {t, v} -> is_nil(t) or is_nil(v) end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  # Reechantillonne une serie sur chaque seconde entiere, par interpolation
  # lineaire entre deux points connus.
  #
  # La distance et la frequence cardiaque passent par la meme fonction, parce
  # que c'est la meme operation : les fichiers Garmin n'echantillonnent pas a
  # 1 Hz, et une serie laissee a trous doit etre comblee avant toute fenetre
  # glissante. Les traiter differemment est precisement ce qui faisait sortir
  # des FC moyennes a 30 bpm, en comptant les secondes sans mesure comme des
  # zeros.
  defp resample([], _size), do: nil

  defp resample([{_t, only}], size), do: List.duplicate(only, size) |> List.to_tuple()

  defp resample(samples, size) do
    samples
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce({[], 0, nil}, fn [{t0, v0}, {t1, v1}], acc ->
      fill_segment(acc, t0, v0, t1, v1)
    end)
    |> then(fn {acc, next, last} ->
      # Queue : de la derniere seconde remplie a la fin de la grille.
      Enum.reduce(next..(size - 1)//1, acc, fn _s, a -> [last | a] end)
    end)
    |> Enum.reverse()
    |> List.to_tuple()
  end

  defp fill_segment({acc, next, _last}, t0, v0, t1, v1) do
    span = t1 - t0
    # Au dela du seuil de pause, on gele la valeur au lieu d'interpoler. Pour
    # la distance c'est le choix pessimiste voulu ; pour la FC c'est aussi le
    # bon comportement, puisque rien ne permet de deviner son evolution
    # pendant un arret.
    paused? = span > @pause_gap_s
    from = max(next, trunc(t0))
    to = trunc(t1)

    if to < from do
      {acc, next, v1}
    else
      acc = Enum.reduce(from..to, acc, &[at_second(&1, t0, v0, v1, span, paused?) | &2])

      {acc, to + 1, v1}
    end
  end

  defp at_second(_second, _t0, v0, _v1, _span, true), do: v0
  defp at_second(_second, _t0, _v0, v1, span, _paused?) when span <= 0, do: v1
  defp at_second(second, t0, v0, v1, span, _paused?), do: v0 + (v1 - v0) * (second - t0) / span

  # Sommes prefixes de FC : `hr_prefix[i]` est la somme des FC de la seconde 0
  # a i-1, ce qui rend la moyenne d'une fenetre independante de sa longueur.
  defp hr_prefix(_times, nil, _size), do: nil

  defp hr_prefix(times, hrs, size) do
    case resample(paired(times, hrs), size) do
      nil ->
        nil

      grid ->
        {prefix, total} =
          Enum.map_reduce(0..(size - 1), 0.0, fn s, carried ->
            {carried, carried + elem(grid, s)}
          end)

        # Une case de plus que la grille, pour que la derniere fenetre se lise
        # comme toutes les autres.
        (prefix ++ [total]) |> List.to_tuple()
    end
  end

  defp window_hr(%{hr_prefix: nil}, _start, _duration), do: nil

  defp window_hr(%{hr_prefix: prefix}, start, duration) do
    finish = min(start + duration, tuple_size(prefix) - 1)
    span = finish - start

    if span > 0 do
      round((elem(prefix, finish) - elem(prefix, start)) / span)
    end
  end

  @doc "Libelle lisible d'un effort, pour l'affichage."
  def label(%{kind: "distance", distance_m: m}), do: Pace.distance_label(m)
  def label(%{duration_s: s}), do: Pace.format_duration(s)
end
