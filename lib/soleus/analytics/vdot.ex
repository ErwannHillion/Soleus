defmodule Soleus.Analytics.Vdot do
  @moduledoc """
  VDOT de Daniels : la VO2max equivalente deduite d'une performance.

  L'interet du VDOT n'est pas la valeur elle-meme mais qu'il soit une echelle
  unique : un 5 000 m et un semi courus au meme niveau donnent le meme VDOT.
  C'est ce qui permet de comparer des performances sur des distances
  differentes, et d'en deriver des allures d'entrainement coherentes.

  Les deux equations viennent de Daniels et Gilbert. La premiere donne le cout
  en oxygene d'une vitesse, la seconde la fraction de VO2max qu'un effort de
  cette duree mobilise.
  """

  @doc """
  VDOT d'une performance.

      iex> Soleus.Analytics.Vdot.from_performance(5000, 1369) |> Float.round(2)
      42.67
  """
  @spec from_performance(number(), number()) :: float() | nil
  def from_performance(distance_m, time_s)
      when is_number(distance_m) and is_number(time_s) and distance_m > 0 and time_s > 0 do
    minutes = time_s / 60.0
    velocity = distance_m / minutes

    oxygen_cost(velocity) / max_fraction(minutes)
  end

  def from_performance(_distance_m, _time_s), do: nil

  @doc """
  Vitesse, en m/s, correspondant a un pourcentage de VDOT.

  Resolution numerique par dichotomie : l'equation du cout en oxygene est un
  polynome du second degre en vitesse, mais l'inverser analytiquement donnerait
  une expression illisible pour un gain nul a cette echelle.
  """
  @spec speed_at(number(), number()) :: float() | nil
  def speed_at(vdot, fraction) when is_number(vdot) and fraction > 0 and fraction <= 1.2 do
    target = vdot * fraction
    # Bornes en m/min : de la marche a un record du monde, l'encadrement est
    # garanti pour toute valeur physiologiquement atteignable.
    bisect(target, 50.0, 700.0, 40) / 60.0
  end

  def speed_at(_vdot, _fraction), do: nil

  @doc """
  Allures d'entrainement derivees du VDOT, en m/s.

  Les pourcentages sont ceux des zones de Daniels : facile pour le volume,
  marathon, seuil pour le travail de tempo, intervalle pour la VO2max.
  """
  @spec training_speeds(number()) :: %{atom() => float() | nil}
  def training_speeds(vdot) do
    %{
      easy: speed_at(vdot, 0.70),
      marathon: speed_at(vdot, 0.84),
      threshold: speed_at(vdot, 0.88),
      interval: speed_at(vdot, 0.98),
      repetition: speed_at(vdot, 1.05)
    }
  end

  # VO2 en ml/kg/min pour une vitesse en m/min.
  defp oxygen_cost(velocity), do: -4.60 + 0.182258 * velocity + 0.000104 * velocity * velocity

  # Fraction de VO2max mobilisable sur une duree donnee, en minutes. Elle tend
  # vers 1 sur les efforts courts et vers 0.8 sur les tres longs.
  defp max_fraction(minutes) do
    0.8 + 0.1894393 * :math.exp(-0.012778 * minutes) +
      0.2989558 * :math.exp(-0.1932605 * minutes)
  end

  defp bisect(_target, low, high, 0), do: (low + high) / 2.0

  defp bisect(target, low, high, steps) do
    mid = (low + high) / 2.0

    if oxygen_cost(mid) < target do
      bisect(target, mid, high, steps - 1)
    else
      bisect(target, low, mid, steps - 1)
    end
  end
end
