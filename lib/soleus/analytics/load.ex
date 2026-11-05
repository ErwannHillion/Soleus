defmodule Soleus.Analytics.Load do
  @moduledoc """
  Charge d'entrainement : un nombre par seance, puis le modele de Banister.

  ## Pourquoi un score et pas la distance

  Dix kilometres en footing et dix kilometres a allure seuil ne coutent pas la
  meme chose. La distance ne distingue pas les deux, le temps non plus. Il faut
  une grandeur qui integre l'intensite, sinon la courbe de forme ne veut rien
  dire.

  Deux facons de l'obtenir, par ordre de preference :

    * **rTSS**, a partir de l'allure rapportee a la vitesse critique. C'est le
      choix par defaut en course a pied : l'allure est mesuree directement,
      alors que la frequence cardiaque derive avec la chaleur, la fatigue, le
      cafe et le placement de la ceinture.
    * **TRIMP** de Banister, a partir de la frequence cardiaque. Le repli quand
      la vitesse critique n'est pas encore connue, ou pour les sports ou
      l'allure ne veut rien dire (renforcement, velo sans capteur).

  ## Le modele de Banister

  Deux moyennes exponentielles de la charge quotidienne, de constantes de temps
  differentes : la condition physique se construit lentement et se perd
  lentement (42 jours), la fatigue monte et redescend vite (7 jours). Leur
  difference est la forme.

  C'est un modele grossier — il ne sait rien du type de seance ni du sommeil —
  mais c'est celui qui tient depuis les annees 1970 et qui capture le fait
  central : la performance arrive quand la charge chronique est haute **et**
  que la fatigue aigue est retombee.
  """

  alias Soleus.Analytics.{CriticalSpeed, DailyLoad}

  @ctl_days 42
  @atl_days 7

  # Coefficients du TRIMP ponderes par la frequence cardiaque. Ils ne sont pas
  # les memes selon le sexe : la courbe lactate/FC differe, et Banister a
  # publie deux jeux de constantes.
  @trimp_coefficients %{
    "male" => {0.64, 1.92},
    "female" => {0.86, 1.67}
  }

  def ctl_days, do: @ctl_days
  def atl_days, do: @atl_days

  @doc """
  TRIMP ponderé d'une seance.

  Rend `nil` si la frequence cardiaque manque ou si les reperes de l'athlete
  sont inconnus : une charge inventee fausserait toute la courbe de forme en
  aval, mieux vaut une seance sans score.
  """
  @spec trimp(map(), map()) :: float() | nil
  def trimp(%{moving_time_s: t, avg_hr: hr}, %{hr_rest: rest, hr_max: max, sex: sex})
      when is_number(t) and is_number(hr) and is_number(rest) and is_number(max) and max > rest do
    ratio = (hr - rest) / (max - rest)

    if ratio <= 0 do
      0.0
    else
      {a, b} = Map.get(@trimp_coefficients, sex, @trimp_coefficients["male"])
      t / 60.0 * ratio * a * :math.exp(b * ratio)
    end
  end

  def trimp(_activity, _athlete), do: nil

  @doc """
  Score de stress base sur l'allure, rapporte a la vitesse critique.

  Par construction, une heure exactement a la vitesse critique vaut 100.

      iex> Soleus.Analytics.Load.rtss(%{moving_time_s: 3600, avg_speed_ms: 4.0}, 4.0)
      100.0
  """
  @spec rtss(map(), number() | nil) :: float() | nil
  def rtss(%{moving_time_s: t, avg_speed_ms: speed}, cs_ms)
      when is_number(t) and is_number(speed) and is_number(cs_ms) and cs_ms > 0 do
    intensity = speed / cs_ms
    # L'intensite au carre, et non lineaire : le cout physiologique croit plus
    # vite que l'allure. C'est ce qui fait qu'une demi-heure de seuil pese plus
    # lourd qu'une heure de footing.
    t / 3600.0 * intensity * intensity * 100.0
  end

  def rtss(_activity, _cs_ms), do: nil

  @doc """
  Facteur d'intensite : l'allure moyenne rapportee a la vitesse critique.

  Au dessus de 1, la seance s'est courue plus vite que le seuil soutenable.
  """
  @spec intensity_factor(map(), number() | nil) :: float() | nil
  def intensity_factor(%{avg_speed_ms: speed}, cs_ms)
      when is_number(speed) and is_number(cs_ms) and cs_ms > 0,
      do: speed / cs_ms

  def intensity_factor(_activity, _cs_ms), do: nil

  @doc """
  Choisit le meilleur score disponible pour une seance.

  Rend `{score, source}` ou `nil`, pour que l'interface puisse dire d'ou vient
  le chiffre au lieu de l'afficher comme une verite sans origine.
  """
  @spec score(map(), map(), CriticalSpeed.t() | nil) ::
          {float(), :rtss | :trimp | :duration} | nil
  def score(activity, athlete, cs_fit) do
    cs = cs_fit && cs_fit.cs_ms

    # Les deux candidats sont calcules avant le `cond` : une affectation dans
    # une clause ne sort pas de sa portee, et la lecture y gagne.
    pace_based = if activity.sport == "run", do: rtss(activity, cs)
    hr_based = trimp(activity, athlete)

    cond do
      is_number(pace_based) -> {pace_based, :rtss}
      is_number(hr_based) -> {hr_based, :trimp}
      is_number(activity.moving_time_s) -> {duration_fallback(activity), :duration}
      true -> nil
    end
  end

  # Dernier recours, pour que des seances sans capteur n'apparaissent pas comme
  # des jours de repos : 50 points par heure, soit l'ordre de grandeur d'un
  # effort modere. Marque comme tel pour que l'interface puisse le signaler.
  defp duration_fallback(%{moving_time_s: t}), do: t / 3600.0 * 50.0

  @doc """
  Deroule le modele de Banister sur une serie de jours consecutifs.

  `days` est une liste de `%{date:, load:}` triee par date croissante, **sans
  trou** : les jours de repos doivent y figurer avec une charge nulle, sinon
  la decroissance exponentielle est sous-estimee et la fatigue reste
  artificiellement haute.

  `seed` reprend l'etat au dernier jour precedant la serie, ce qui permet de
  recalculer une fenetre recente sans relire tout l'historique.
  """
  @spec banister([map()], %{ctl: float(), atl: float()}) :: [map()]
  def banister(days, seed \\ %{ctl: 0.0, atl: 0.0}) do
    k_ctl = 1.0 - :math.exp(-1.0 / @ctl_days)
    k_atl = 1.0 - :math.exp(-1.0 / @atl_days)

    days
    |> Enum.map_reduce(seed, fn day, %{ctl: prev_ctl, atl: prev_atl} ->
      load = day.load || 0.0
      ctl = prev_ctl + (load - prev_ctl) * k_ctl
      atl = prev_atl + (load - prev_atl) * k_atl

      row =
        Map.merge(day, %{
          ctl: ctl,
          atl: atl,
          # La forme du jour se lit sur l'etat **de la veille** : le matin, la
          # seance du jour n'a pas encore ete faite. C'est la convention de
          # TrainingPeaks, et celle qui rend le chiffre utilisable pour
          # decider quoi faire aujourd'hui.
          tsb: prev_ctl - prev_atl
        })

      {row, %{ctl: ctl, atl: atl}}
    end)
    |> elem(0)
    |> with_ramp_rate()
  end

  # Variation de charge chronique sur sept jours. Au dela d'environ +5 par
  # semaine, la litterature sur la blessure devient nettement moins amicale.
  defp with_ramp_rate(rows) do
    indexed = List.to_tuple(rows)

    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, i} ->
      ramp = if i >= 7, do: row.ctl - elem(indexed, i - 7).ctl
      Map.put(row, :ramp_rate, ramp)
    end)
  end

  @doc """
  Lecture en clair de la forme du jour.

  Les seuils sont ceux d'usage : au dela de +15 on est frais mais la charge
  chronique s'erode, en dessous de -25 on accumule plus de fatigue qu'on n'en
  absorbe.
  """
  @spec interpret(number() | nil) :: {atom(), String.t()}
  def interpret(nil), do: {:unknown, "Pas assez de donnees"}
  def interpret(tsb) when tsb > 20, do: {:detrained, "Trop frais — la charge retombe"}
  def interpret(tsb) when tsb > 5, do: {:fresh, "Frais — jour de course"}
  def interpret(tsb) when tsb > -10, do: {:neutral, "Equilibre"}
  def interpret(tsb) when tsb > -25, do: {:productive, "Charge productive"}
  def interpret(_tsb), do: {:overreaching, "Surcharge — attention"}

  @doc "Etat de Banister a reprendre pour un recalcul partiel."
  def seed_from(%DailyLoad{ctl: ctl, atl: atl}), do: %{ctl: ctl, atl: atl}
  def seed_from(nil), do: %{ctl: 0.0, atl: 0.0}
end
