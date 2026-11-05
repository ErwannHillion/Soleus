defmodule Soleus.Analytics.CriticalSpeed do
  @moduledoc """
  Modele de vitesse critique a deux parametres.

      d(t) = CS * t + D'

  `CS` est la vitesse que l'aerobie peut soutenir, en m/s. `D'` est la reserve
  anaerobie, en metres : le capital qu'on depense en allant plus vite que CS,
  et qui ne se recharge qu'en ralentissant en dessous.

  L'interet par rapport a la formule de Riegel est qu'il separe deux qualites
  que Riegel confond. Deux coureurs qui courent le 10 km dans le meme temps
  peuvent avoir une CS tres differente : celui qui a un gros `D'` est un
  coureur de vitesse qui tient, l'autre un coureur de fond. Ils ne doivent pas
  s'entrainer pareil, et c'est la CS qu'il faut regarder progresser.

  ## Plage de validite

  L'ajustement n'utilise que les efforts de 2 a 20 minutes. En dessous, la
  filiere anaerobie domine et la relation n'est plus lineaire ; au dessus, la
  fatigue fait decrocher les points sous le modele, qui devient optimiste.
  C'est la plage ou la litterature etablit la linearite, et l'elargir pour
  gagner des points degraderait l'ajustement au lieu de l'ameliorer.
  """

  alias Soleus.Analytics.Regression

  @min_duration 120
  @max_duration 1200

  @type t :: %{
          cs_ms: float(),
          d_prime_m: float(),
          r2: float(),
          sample_count: pos_integer()
        }

  @doc "Bornes de duree retenues pour l'ajustement, en secondes."
  def window, do: {@min_duration, @max_duration}

  @doc """
  Ajuste le modele sur une liste d'efforts records.

  Chaque effort est une map contenant au moins `:duration_s` et `:distance_m`.
  """
  @spec fit([map()]) :: {:ok, t()} | :error
  def fit(efforts) do
    points =
      efforts
      |> Enum.filter(&in_window?/1)
      |> Enum.map(&{&1.duration_s * 1.0, &1.distance_m * 1.0})

    with {:ok, reg} <- Regression.ols(points),
         true <- plausible?(reg) do
      {:ok,
       %{
         cs_ms: reg.slope,
         d_prime_m: reg.intercept,
         r2: reg.r2,
         sample_count: reg.n
       }}
    else
      _ -> :error
    end
  end

  @doc """
  Temps predit sur `distance_m`, en secondes.

  Le modele n'a de sens que pour une distance plus longue que la reserve
  anaerobie : en dessous, l'effort se court entierement sur `D'` et la
  formule rendrait un temps nul ou negatif.
  """
  @spec predict(t(), number()) :: float() | nil
  def predict(%{cs_ms: cs, d_prime_m: d_prime}, distance_m)
      when distance_m > d_prime and cs > 0 do
    (distance_m - d_prime) / cs
  end

  def predict(_fit, _distance_m), do: nil

  @doc """
  Vitesse soutenable pendant `duration_s`, en m/s.

  C'est la lecture inverse du modele, celle qui sert a proposer des allures de
  seance : `D'` se repartit sur la duree et s'ajoute a `CS`.
  """
  @spec speed_for(t(), number()) :: float() | nil
  def speed_for(%{cs_ms: cs, d_prime_m: d_prime}, duration_s) when duration_s > 0 do
    cs + d_prime / duration_s
  end

  def speed_for(_fit, _duration_s), do: nil

  defp in_window?(%{duration_s: d}), do: d >= @min_duration and d <= @max_duration
  defp in_window?(_), do: false

  # Un ajustement peut etre numeriquement correct et physiologiquement absurde
  # : une CS negative, ou une reserve anaerobie de 3 km. Ca arrive quand les
  # efforts fournis viennent de seances a allure trop homogene, ou le nuage de
  # points est presque vertical. Mieux vaut ne rien afficher que d'afficher ca.
  defp plausible?(%{slope: cs, intercept: d_prime, r2: r2}) do
    cs > 0.5 and cs < 12.0 and d_prime > 0 and d_prime < 1000 and r2 > 0.9
  end
end
