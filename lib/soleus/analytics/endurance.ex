defmodule Soleus.Analytics.Endurance do
  @moduledoc """
  Loi de puissance de la courbe vitesse-duree, soit un Riegel personnalise.

      d = a * t^b

  Riegel a publie `t2 = t1 * (d2/d1)^1.06`, ou 1.06 est une moyenne mesuree
  sur une population. Ce module ajuste l'exposant sur **les** efforts de
  l'athlete au lieu de reprendre la moyenne : un coureur dont l'endurance est
  le point fort a un exposant plus proche de 1, un coureur de vitesse s'en
  eloigne. Sur un marathon, l'ecart entre 1.06 et un exposant reel de 1.10
  depasse les dix minutes.

  L'ajustement se fait en log-log, ou la loi de puissance devient une droite :

      log d = log a + b * log t

  La plage va de 3 minutes a 1 h 30. Elle est volontairement plus large que
  celle de la vitesse critique : c'est precisement la decroissance lente de la
  courbe sur les longues durees qu'on cherche a mesurer ici.
  """

  alias Soleus.Analytics.Regression

  @min_duration 180
  @max_duration 5400

  @type t :: %{
          log_a: float(),
          b: float(),
          riegel_exponent: float(),
          r2: float(),
          sample_count: pos_integer()
        }

  def window, do: {@min_duration, @max_duration}

  @doc "Ajuste la loi de puissance sur une liste d'efforts records."
  @spec fit([map()]) :: {:ok, t()} | :error
  def fit(efforts) do
    points =
      efforts
      |> Enum.filter(&in_window?/1)
      |> Enum.map(&{:math.log(&1.duration_s), :math.log(&1.distance_m)})

    with {:ok, reg} <- Regression.ols(points),
         true <- plausible?(reg) do
      {:ok,
       %{
         log_a: reg.intercept,
         b: reg.slope,
         # L'exposant de Riegel est l'inverse de la pente log-log : Riegel
         # exprime le temps en fonction de la distance, la loi de puissance
         # la distance en fonction du temps.
         riegel_exponent: 1.0 / reg.slope,
         r2: reg.r2,
         sample_count: reg.n
       }}
    else
      _ -> :error
    end
  end

  @doc "Temps predit sur `distance_m`, en secondes."
  @spec predict(t(), number()) :: float() | nil
  def predict(%{log_a: log_a, b: b}, distance_m) when distance_m > 0 and b > 0 do
    :math.exp((:math.log(distance_m) - log_a) / b)
  end

  def predict(_fit, _distance_m), do: nil

  @doc """
  Riegel classique, a partir d'une seule performance de reference.

  Sert de repli quand il n'y a pas encore assez d'efforts records pour ajuster
  un exposant personnel, par exemple au premier import.
  """
  @spec riegel(number(), number(), number(), number()) :: float()
  def riegel(known_distance_m, known_time_s, target_distance_m, exponent \\ 1.06) do
    known_time_s * :math.pow(target_distance_m / known_distance_m, exponent)
  end

  defp in_window?(%{duration_s: d}), do: d >= @min_duration and d <= @max_duration
  defp in_window?(_), do: false

  # Un exposant hors de 0.80..1.00 ne decrit pas un coureur humain : a 1.0 la
  # vitesse ne baisserait pas du tout avec la distance, en dessous de 0.80 elle
  # s'ecroulerait plus vite que chez un sprinteur pur.
  defp plausible?(%{slope: b, r2: r2}), do: b > 0.80 and b < 1.0 and r2 > 0.95
end
