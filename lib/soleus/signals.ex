defmodule Soleus.Signals do
  @moduledoc """
  Ce qui merite d'etre regarde aujourd'hui.

  Un tableau de bord qui se contente d'afficher des chiffres laisse a
  l'athlete tout le travail d'interpretation, et le reporte en pratique a
  jamais. Ce module fait le tour des mesures et ne remonte que ce qui sort de
  l'ordinaire.

  ## Les trois regles de conception

  **Un signal dit ce qu'il a vu, pas ce qu'il faut faire.** « Cinquante-trois
  pour cent du temps au dessus de la zone 2 » est une observation verifiable ;
  « fais plus de footing » est un conseil que ce module n'a pas les moyens de
  donner — il ne sait rien des objectifs ni du calendrier.

  **Chaque seuil a une origine citable**, et elle figure dans le commentaire
  du signal. Un seuil invente aurait l'air aussi serieux que les autres, ce
  qui est precisement le probleme.

  **Le silence est un resultat valable.** Aucun signal veut dire que rien ne
  sort de l'ordinaire, pas que l'analyse a echoue. L'interface doit le dire
  ainsi plutot que d'afficher un panneau vide.
  """

  alias Soleus.Analytics
  alias Soleus.Analytics.Zones
  alias Soleus.Health
  alias Soleus.Training

  @type level :: :alert | :watch | :info

  @type t :: %{
          key: atom(),
          level: level(),
          title: String.t(),
          detail: String.t(),
          value: String.t() | nil
        }

  @doc "Tous les signaux actifs, du plus preoccupant au moins."
  @spec all(String.t()) :: [t()]
  def all(sport \\ "run") do
    today = Date.utc_today()

    [
      polarisation(sport, today),
      ramp_rate(),
      acwr(),
      hrv_streak(),
      resting_hr(),
      sleep_trend(),
      quality_gap(sport),
      monotony()
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&rank(&1.level))
  end

  defp rank(:alert), do: 0
  defp rank(:watch), do: 1
  defp rank(:info), do: 2

  # -- repartition de l'intensite ---------------------------------------------

  # Le modele polarise situe autour de 80 % le temps passe sous le premier
  # seuil. La mesure se fait par l'**allure** et non par la frequence
  # cardiaque.
  #
  # Ce n'etait pas le cas au depart, et le resultat etait faux. Deux raisons
  # se cumulaient. D'une part, le palier zone 2 / zone 3 de Garmin tombe a
  # 70 % de la frequence maximale, nettement sous le premier seuil d'un
  # coureur entraine : des allures franchement faciles etaient comptees comme
  # moderees. D'autre part, la frequence cardiaque met parfois plus de dix
  # minutes a monter, donc elle decrit mal l'effort du debut de seance — on a
  # releve une fenetre de quinze minutes a 5:23/km avec 125 battements.
  #
  # Sur le meme historique, la lecture par allure donne 72 % de temps facile
  # la ou la lecture par zones Garmin en donnait 34. L'allure est immediate ;
  # elle ne se trompe pas de grandeur.
  defp polarisation(_sport, today) do
    bands = Zones.pace_distribution(Date.add(today, -90), today)
    total = Enum.sum(bands)

    if total > 3600 do
      easy = Zones.easy_pace_share(bands)
      grey = Zones.grey_pace_share(bands)

      cond do
        easy >= 70 and grey <= 15 -> nil
        easy >= 70 -> grey_zone_signal(grey)
        easy >= 55 -> polarisation_signal(:watch, easy, "s'ecarte du modele polarise")
        true -> polarisation_signal(:alert, easy, "s'en eloigne nettement")
      end
    end
  end

  defp polarisation_signal(level, easy, verdict) do
    signal(
      :polarisation,
      level,
      "Peu de temps en allure facile",
      "#{pct(easy)} du temps plus lent que l'allure marathon sur 90 jours, contre 80 % dans le modele polarise. La repartition #{verdict}.",
      pct(easy)
    )
  end

  # La zone grise est le reproche classique fait aux plans mal construits :
  # trop dur pour recuperer, trop facile pour developper.
  defp grey_zone_signal(grey) when grey > 15 do
    signal(
      :grey_zone,
      :watch,
      "Temps en zone grise",
      "#{pct(grey)} du temps entre allure marathon et allure seuil. Ni assez facile pour recuperer, ni assez dur pour developper.",
      pct(grey)
    )
  end

  defp grey_zone_signal(_grey), do: nil

  # -- charge -----------------------------------------------------------------

  # Au dela d'environ cinq points de charge chronique gagnes en une semaine,
  # la litterature sur la blessure devient nettement moins amicale.
  defp ramp_rate do
    case Analytics.current_form() do
      %{ramp_rate: rate} when is_number(rate) and rate > 5 ->
        signal(
          :ramp,
          :alert,
          "Montee en charge rapide",
          "La charge chronique a gagne #{one(rate)} points en sept jours. Au dela de cinq, le risque de blessure augmente nettement.",
          "+#{one(rate)}"
        )

      %{ramp_rate: rate} when is_number(rate) and rate < -5 ->
        signal(
          :ramp,
          :info,
          "Charge en baisse",
          "La charge chronique a perdu #{one(abs(rate))} points en sept jours. Normal en affutage ou apres une coupure.",
          one(rate)
        )

      _steady ->
        nil
    end
  end

  # Rapport charge aigue sur charge chronique, tel que Garmin le calcule. La
  # fenetre 0,8-1,3 est celle ou la litterature situe le meilleur compromis
  # entre progression et risque.
  defp acwr do
    case Health.latest() do
      %{garmin_acwr: ratio} when is_number(ratio) and ratio > 1.5 ->
        signal(
          :acwr,
          :alert,
          "Charge aigue elevee",
          "Rapport aigu sur chronique a #{two(ratio)}, contre une fenetre usuelle de 0,8 a 1,3.",
          two(ratio)
        )

      %{garmin_acwr: ratio} when is_number(ratio) and ratio < 0.8 ->
        signal(
          :acwr,
          :info,
          "Charge aigue basse",
          "Rapport aigu sur chronique a #{two(ratio)}. La forme monte, la condition s'erode doucement.",
          two(ratio)
        )

      _in_range ->
        nil
    end
  end

  # -- sante ------------------------------------------------------------------

  # Trois nuits consecutives sous la fourchette personnelle. Une seule nuit
  # basse arrive a tout le monde ; c'est la repetition qui porte un signal.
  @streak_days 3

  defp hrv_streak do
    days = recent_health(10)

    streak =
      days
      |> Enum.take_while(fn d ->
        is_number(d.hrv_overnight) and is_number(d.hrv_baseline_low) and
          d.hrv_overnight < d.hrv_baseline_low
      end)
      |> length()

    if streak >= @streak_days do
      signal(
        :hrv,
        :alert,
        "Variabilite cardiaque basse",
        "#{streak} nuits de suite sous ta fourchette normale. Fatigue, maladie qui couve ou stress — a croiser avec le reste.",
        "#{streak} nuits"
      )
    end
  end

  defp resting_hr do
    case recent_health(2) do
      [%{resting_hr: hr, hr_baseline_high: high} | _]
      when is_number(hr) and is_number(high) and hr > high ->
        signal(
          :resting_hr,
          :watch,
          "Frequence au repos elevee",
          "#{hr} battements ce matin, au dessus de ta fourchette normale qui plafonne a #{high}.",
          "#{hr} bpm"
        )

      _normal ->
        nil
    end
  end

  # Une demi-heure de sommeil en moins sur la semaine par rapport au mois :
  # l'ecart est assez net pour ne pas etre du bruit, et assez courant pour
  # valoir un rappel.
  defp sleep_trend do
    today = Date.utc_today()
    week = Health.averages(Date.add(today, -7), today)[:sleep_total_s]
    month = Health.averages(Date.add(today, -30), today)[:sleep_total_s]

    if is_number(week) and is_number(month) and month - week > 1800 do
      signal(
        :sleep,
        :watch,
        "Sommeil en baisse",
        "#{minutes(month - week)} de moins par nuit cette semaine que sur le mois.",
        "−#{minutes(month - week)}"
      )
    end
  end

  # -- entrainement -----------------------------------------------------------

  defp quality_gap(sport) do
    case Training.days_since_quality(sport) do
      days when is_integer(days) and days >= 14 ->
        signal(
          :quality,
          :watch,
          "Pas de seance de qualite recente",
          "#{days} jours depuis la derniere seance avec plus de dix minutes au dessus de la zone 2.",
          "#{days} j"
        )

      _recent ->
        nil
    end
  end

  # Monotonie de Foster : la moyenne de la charge quotidienne divisee par son
  # ecart-type, sur sept jours. Une monotonie elevee signifie que tous les
  # jours se ressemblent, ce qui prive le corps des creux ou l'adaptation se
  # fait. Foster situe le seuil d'alerte autour de 2.
  defp monotony do
    loads = Analytics.load_series(7) |> Enum.map(&(&1.load || 0.0))

    with 7 <- length(loads),
         mean when mean > 0 <- Enum.sum(loads) / 7,
         sd when sd > 0 <- standard_deviation(loads, mean),
         ratio when ratio > 2.0 <- mean / sd do
      signal(
        :monotony,
        :watch,
        "Semaine monotone",
        "Monotonie a #{two(ratio)} : les sept derniers jours se ressemblent trop. C'est dans les creux que l'adaptation se fait.",
        two(ratio)
      )
    else
      _varied -> nil
    end
  end

  defp standard_deviation(values, mean) do
    values
    |> Enum.map(&((&1 - mean) * (&1 - mean)))
    |> Enum.sum()
    |> Kernel./(length(values))
    |> :math.sqrt()
  end

  # -- primitives -------------------------------------------------------------

  defp recent_health(days) do
    today = Date.utc_today()

    Date.add(today, -days)
    |> Health.range(today)
    |> Enum.reverse()
  end

  defp signal(key, level, title, detail, value),
    do: %{key: key, level: level, title: title, detail: detail, value: value}

  defp pct(value), do: "#{round(value)} %"
  defp one(value), do: value |> Float.round(1) |> to_string()
  defp two(value), do: value |> Float.round(2) |> to_string()
  defp minutes(seconds), do: "#{round(seconds / 60)} min"
end
