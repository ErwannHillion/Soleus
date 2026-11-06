defmodule Soleus.Coaching.Feasibility do
  @moduledoc """
  Un objectif est-il atteignable dans le temps disponible ?

  ## La methode

  Trois chiffres suffisent a repondre :

    1. la vitesse critique **requise** pour courir la distance dans le temps
       vise — obtenue en inversant la cascade de prediction de
       `Soleus.Analytics` ;
    2. la vitesse critique **actuelle**, mesuree sur la courbe des meilleurs
       efforts ;
    3. le **rythme de progression** credible sur la periode.

  L'ecart divise par le rythme donne le nombre de semaines necessaires. S'il
  depasse le temps disponible, l'objectif ne tient pas, et on le dit.

  ## Le rythme de progression

  C'est le point faible, et il faut le nommer. Quand l'historique porte une
  tendance mesurable, on l'utilise : c'est la meilleure estimation possible,
  puisqu'elle vient de cet athlete. Quand il n'y en a pas — serie trop courte,
  ou progression nulle sur la periode — on retombe sur un rythme generique et
  **l'interface doit le dire**, parce qu'une projection batie sur une moyenne
  de population ne vaut pas celle batie sur les donnees de la personne.

  Le rythme generique retenu est volontairement conservateur. Un coureur
  regulier qui ajoute une vraie charge progresse de l'ordre de un a deux pour
  cent de vitesse critique sur deux a trois mois ; on retient le bas de cette
  fourchette. Annoncer large ferait des plans flatteurs et faux.
  """

  alias Soleus.Analytics
  alias Soleus.Analytics.CriticalSpeed
  alias Soleus.Analytics.Endurance

  # Au dela de cette duree, la cascade de prediction quitte le modele de
  # vitesse critique pour Riegel. L'inversion doit suivre la meme frontiere,
  # sinon le plan viserait une vitesse critique qui ne produit pas le temps
  # affiche ailleurs dans l'application.
  @cs_max_duration 1200

  # Progression generique, en fraction de vitesse critique par semaine. Soit
  # environ 1,3 % sur trois mois.
  @generic_weekly_gain 0.001

  @type t :: %{
          required_cs: float() | nil,
          current_cs: float() | nil,
          weekly_gain: float(),
          gain_source: :personal | :generic,
          weeks_available: number(),
          weeks_needed: float() | nil,
          verdict: :reached | :reachable | :tight | :out_of_reach | :unknown,
          achievable_time_s: float() | nil
        }

  @doc """
  Evalue un objectif.

  `effective_distance_m` inclut deja la correction de denivele.
  """
  @spec assess(float(), pos_integer() | nil, number(), String.t()) :: t()
  def assess(effective_distance_m, target_time_s, weeks_available, sport \\ "run") do
    fit = Analytics.current_fit(sport)
    {weekly_gain, source} = weekly_gain(sport)

    base = %{
      weekly_gain: weekly_gain,
      gain_source: source,
      weeks_available: weeks_available,
      current_cs: fit && fit.cs_ms,
      required_cs: nil,
      weeks_needed: nil,
      verdict: :unknown,
      achievable_time_s: nil
    }

    case cs_of(fit) do
      nil -> base
      cs -> evaluate(base, cs, fit, effective_distance_m, target_time_s, weeks_available)
    end
  end

  defp evaluate(base, cs, fit, distance, target_time_s, weeks) do
    exponent = fit.endurance_exponent || 1.06
    projected_cs = cs.cs_ms + cs.cs_ms * base.weekly_gain * weeks
    achievable = predict(%{cs | cs_ms: projected_cs}, exponent, distance)

    base = %{base | achievable_time_s: achievable}

    case target_time_s do
      nil ->
        # Sans objectif saisi, le temps atteignable **est** l'objectif.
        %{base | verdict: :reachable}

      time ->
        required = required_cs(distance, time, cs.d_prime_m, exponent)
        weeks_needed = weeks_needed(cs.cs_ms, required, base.weekly_gain)

        %{
          base
          | required_cs: required,
            weeks_needed: weeks_needed,
            verdict: verdict(weeks_needed, weeks)
        }
    end
  end

  @doc """
  Vitesse critique requise pour couvrir `distance` en `time`.

  C'est l'inverse exact de `Soleus.Analytics.predictions/3`, frontiere
  comprise : en dessous de vingt minutes le modele a deux parametres
  s'inverse directement, au dela c'est la relation de Riegel ancree sur la
  performance de reference a vingt minutes qu'il faut retourner.
  """
  @spec required_cs(number(), number(), number(), number()) :: float() | nil
  def required_cs(distance, time, d_prime, exponent) do
    if time <= @cs_max_duration do
      direct = (distance - d_prime) / time
      if direct > 0, do: direct
    else
      # time = 1200 * (distance / anchor)^exponent, avec anchor = cs*1200 + d'
      anchor = distance / :math.pow(time / @cs_max_duration, 1 / exponent)
      cs = (anchor - d_prime) / @cs_max_duration
      if cs > 0, do: cs
    end
  end

  defp predict(cs, exponent, distance) do
    estimate = CriticalSpeed.predict(cs, distance)

    if is_number(estimate) and estimate <= @cs_max_duration do
      estimate
    else
      anchor_distance = cs.cs_ms * @cs_max_duration + cs.d_prime_m
      Endurance.riegel(anchor_distance, @cs_max_duration * 1.0, distance, exponent)
    end
  end

  defp weeks_needed(_current, nil, _gain), do: nil

  defp weeks_needed(current, required, _gain) when required <= current, do: 0.0

  defp weeks_needed(current, required, gain) when gain > 0 do
    (required - current) / (current * gain)
  end

  defp weeks_needed(_current, _required, _gain), do: nil

  # La marge de 15 % separe « atteignable » de « juste » : un plan qui tombe
  # pile le jour de la course ne laisse aucune place a une semaine malade, et
  # l'athlete doit le savoir avant de s'engager.
  defp verdict(nil, _available), do: :unknown
  defp verdict(needed, _available) when needed <= 0.0, do: :reached
  defp verdict(needed, available) when needed <= available * 0.85, do: :reachable
  defp verdict(needed, available) when needed <= available, do: :tight
  defp verdict(_needed, _available), do: :out_of_reach

  # La pente mesuree sur l'historique d'ajustements, ramenee en fraction de
  # vitesse critique par semaine. Nulle ou negative, elle ne peut pas servir a
  # projeter une progression : on bascule alors sur le rythme generique.
  defp weekly_gain(sport) do
    with {:ok, projection} <- personal_trend(sport),
         true <- projection > 0 do
      {projection, :personal}
    else
      _no_trend -> {@generic_weekly_gain, :generic}
    end
  end

  # La meme tendance que celle de la projection d'objectif, et pas un second
  # calcul : `Soleus.Analytics.cs_trend/2` est la source unique. Deux rythmes
  # de progression differents affiches dans la meme application seraient un
  # defaut visible — la page Predictions annoncerait « sans tendance » pendant
  # que le plan promettrait des gains.
  defp personal_trend(sport) do
    with {:ok, trend} <- Analytics.cs_trend(sport),
         %{cs_ms: cs} when is_number(cs) and cs > 0 <- Analytics.current_fit(sport) do
      {:ok, trend.slope * 7 / cs}
    else
      _no_trend -> :error
    end
  end

  defp cs_of(%{cs_ms: cs, d_prime_m: d}) when is_number(cs) and is_number(d),
    do: %{cs_ms: cs, d_prime_m: d}

  defp cs_of(_fit), do: nil

  @doc "Le rythme generique, pour l'afficher quand il est utilise."
  def generic_weekly_gain, do: @generic_weekly_gain

  @doc "Lecture en clair d'un verdict."
  @spec explain(atom()) :: String.t()
  def explain(:reached), do: "Deja a ta portee aujourd'hui"
  def explain(:reachable), do: "Atteignable avec de la marge"
  def explain(:tight), do: "Juste — aucune semaine perdue"
  def explain(:out_of_reach), do: "Hors de portee dans le temps disponible"
  def explain(_unknown), do: "Pas assez de donnees pour trancher"
end
