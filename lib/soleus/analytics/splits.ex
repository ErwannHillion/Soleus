defmodule Soleus.Analytics.Splits do
  @moduledoc """
  Decoupage d'une seance en kilometres, et reechantillonnage de ses series
  pour l'affichage.

  ## Pourquoi reechantillonner

  Une sortie d'une heure porte environ 3 600 points par serie. Les tracer tels
  quels donnerait un chemin SVG de plusieurs centaines de kilo-octets, et la
  charge utile du survol depasserait le demi-megaoctet pour une information
  que l'oeil ne peut pas distinguer : a 1 600 pixels de large, deux points
  consecutifs tombent sur le meme pixel bien avant le millier.

  On ramene donc a quelques centaines de points par moyenne glissante, ce qui
  lisse au passage le bruit du capteur. Les **extremes ne passent pas** par ce
  lissage : les records sont calcules ailleurs, sur la serie complete, par
  `Soleus.Analytics.MeanMaximal`.
  """

  alias Soleus.Analytics.MeanMaximal

  @split_distance 1000.0

  @doc """
  Temps par kilometre, avec la frequence cardiaque moyenne de chaque portion.

  Le dernier kilometre est rendu meme incomplet, marque par `partial?` : une
  sortie de 10,4 km a bien une derniere portion de 400 metres, et la masquer
  ferait disparaitre la fin de la seance.
  """
  @spec per_kilometer(map()) :: [map()]
  def per_kilometer(series) do
    case MeanMaximal.grid(series) do
      nil -> []
      grid -> walk(grid, 0, 0, [])
    end
  end

  defp walk(grid, index, start_second, acc) do
    target = (index + 1) * @split_distance
    start_distance = index * @split_distance

    case cross(grid, start_second, target) do
      {:reached, second} ->
        split = build(grid, index, start_second, second, @split_distance, false)
        walk(grid, index + 1, second, [split | acc])

      {:end, second, distance} ->
        covered = distance - start_distance

        # En dessous de cinquante metres, la portion finale est du bruit
        # d'arret plutot qu'un morceau de course.
        if covered > 50 and second > start_second do
          Enum.reverse([build(grid, index, start_second, second, covered, true) | acc])
        else
          Enum.reverse(acc)
        end
    end
  end

  defp cross(grid, from, target) do
    last = grid.size - 1

    Enum.reduce_while(from..last, nil, fn second, _acc ->
      if elem(grid.distance, second) >= target do
        {:halt, {:reached, second}}
      else
        {:cont, {:end, second, elem(grid.distance, second)}}
      end
    end)
    |> case do
      nil -> {:end, last, elem(grid.distance, last)}
      result -> result
    end
  end

  defp build(grid, index, from, to, distance, partial?) do
    duration = to - from

    %{
      index: index + 1,
      from_s: from,
      duration_s: duration,
      distance_m: distance,
      speed_ms: if(duration > 0, do: distance / duration),
      avg_hr: window_hr(grid, from, duration),
      partial?: partial?
    }
  end

  defp window_hr(%{hr_prefix: nil}, _from, _duration), do: nil

  defp window_hr(%{hr_prefix: prefix}, from, duration) do
    finish = min(from + duration, tuple_size(prefix) - 1)
    span = finish - from

    if span > 0, do: round((elem(prefix, finish) - elem(prefix, from)) / span)
  end

  @doc """
  Reduit une serie a au plus `target` points, par moyenne glissante.

  Rend `[{seconde, valeur}]`. Les fenetres entierement vides sont ecartees
  plutot que ramenees a zero : un capteur qui decroche doit laisser un trou.
  """
  @spec resample(map(), atom(), pos_integer()) :: [{integer(), number()}]
  def resample(series, field, target \\ 400) do
    with times when is_list(times) <- series[:t],
         values when is_list(values) <- series[field],
         pairs = usable(times, values),
         count when count > 0 <- length(pairs) do
      pairs
      |> Enum.chunk_every(max(div(count, target), 1))
      |> Enum.map(&average/1)
      |> Enum.reject(&is_nil/1)
    else
      _nothing -> []
    end
  end

  defp usable(times, values) do
    times
    |> Enum.zip(values)
    |> Enum.reject(fn {t, v} -> is_nil(t) or is_nil(v) end)
  end

  defp average([]), do: nil

  defp average(chunk) do
    n = length(chunk)
    {sum_t, sum_v} = Enum.reduce(chunk, {0, 0.0}, fn {t, v}, {at, av} -> {at + t, av + v} end)
    {round(sum_t / n), sum_v / n}
  end

  @doc """
  Coordonnees du trace, reduites pour l'affichage.

  Rend `[[latitude, longitude]]`, la forme attendue par Leaflet. Le
  reechantillonnage suit la meme logique que les series : un point par seconde
  sur une heure de course donne 3 600 sommets de polyligne, dont l'immense
  majorite tombe sur le meme pixel.

  La moyenne glissante lisse au passage le tremblement du GPS, qui est bien
  visible sur un trace brut en ville.
  """
  @spec coordinates(map(), pos_integer()) :: [[float()]]
  def coordinates(series, target \\ 600) do
    with lats when is_list(lats) <- series[:lat],
         lons when is_list(lons) <- series[:lon],
         pairs = usable(lats, lons),
         count when count > 1 <- length(pairs) do
      pairs
      |> Enum.chunk_every(max(div(count, target), 1))
      |> Enum.map(&mean_coordinate/1)
      |> Enum.reject(&is_nil/1)
    else
      _nothing -> []
    end
  end

  defp mean_coordinate([]), do: nil

  defp mean_coordinate(chunk) do
    n = length(chunk)

    {sum_lat, sum_lon} =
      Enum.reduce(chunk, {0.0, 0.0}, fn {a, o}, {sa, so} -> {sa + a, so + o} end)

    [sum_lat / n, sum_lon / n]
  end
end
