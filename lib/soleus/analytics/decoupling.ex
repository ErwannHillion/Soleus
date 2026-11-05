defmodule Soleus.Analytics.Decoupling do
  @moduledoc """
  Decouplage aerobie, ou derive cardiaque (Pa:HR).

  On compare le rapport allure/frequence cardiaque entre la premiere et la
  seconde moitie de la seance. Si le rapport se degrade, c'est que tenir la
  meme allure a coute de plus en plus de battements : l'endurance aerobie a
  lache avant la fin.

  C'est l'un des rares indicateurs qui dit quelque chose qu'aucun total ne dit.
  Deux footings de dix kilometres identiques en distance, en temps et en FC
  moyenne peuvent avoir un decouplage de 2 % et de 12 % ; le second signale
  une seance trop longue ou trop chaude pour la forme du moment.

  En dessous de 5 % la seance est consideree comme aerobiquement stable, ce qui
  est le repere d'usage.
  """

  # Les points a l'arret sont exclus : a l'arret l'allure tend vers zero et la
  # FC reste haute, ce qui fabrique un decouplage qui n'existe pas. Le seuil
  # correspond a une marche tres lente.
  @min_speed_ms 1.0

  # En dessous de ce nombre de points exploitables par moitie, le rapport est
  # trop bruite pour signifier quoi que ce soit.
  @min_samples_per_half 60

  @doc """
  Decouplage en pourcentage, ou `nil` si la seance ne permet pas de le mesurer.

  Positif : l'efficacite s'est degradee au cours de la seance.
  """
  @spec compute(map()) :: float() | nil
  def compute(series) do
    with speeds when is_list(speeds) <- series[:speed_ms],
         hrs when is_list(hrs) <- series[:hr],
         pairs = usable_pairs(speeds, hrs),
         count when count >= @min_samples_per_half * 2 <- length(pairs) do
      {first, second} = Enum.split(pairs, div(count, 2))

      with r1 when is_float(r1) <- efficiency(first),
           r2 when is_float(r2) <- efficiency(second),
           true <- r1 > 0 do
        (r1 - r2) / r1 * 100.0
      else
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  @doc """
  Lecture en clair du decouplage.

      iex> Soleus.Analytics.Decoupling.interpret(2.1)
      {:stable, "Aerobiquement stable"}
  """
  @spec interpret(number() | nil) :: {atom(), String.t()}
  def interpret(nil), do: {:unknown, "Non mesurable"}
  def interpret(pct) when pct < 0, do: {:negative_split, "Negative split"}
  def interpret(pct) when pct < 5, do: {:stable, "Aerobiquement stable"}
  def interpret(pct) when pct < 10, do: {:drifting, "Derive moderee"}
  def interpret(_pct), do: {:decoupled, "Decouplage marque"}

  defp usable_pairs(speeds, hrs) do
    Enum.zip(speeds, hrs)
    |> Enum.filter(fn {speed, hr} ->
      is_number(speed) and is_number(hr) and speed >= @min_speed_ms and hr > 0
    end)
  end

  # Le rapport est calcule sur les moyennes de la moitie, et non comme la
  # moyenne des rapports point par point : cette derniere est dominee par les
  # points ou la FC est basse et donne un resultat instable.
  defp efficiency([]), do: nil

  defp efficiency(pairs) do
    n = length(pairs)
    {sum_speed, sum_hr} = Enum.reduce(pairs, {0.0, 0.0}, fn {s, h}, {as, ah} -> {as + s, ah + h} end)
    mean_hr = sum_hr / n

    if mean_hr > 0, do: sum_speed / n / mean_hr
  end
end
