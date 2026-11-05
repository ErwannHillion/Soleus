defmodule Soleus.Analytics do
  @moduledoc """
  Le moteur : metriques par seance, charge quotidienne, modeles, projections.

  Le decoupage suit trois echelles de temps, et chacune est materialisee parce
  qu'elle depend de la precedente :

    1. **par seance** — TRIMP, charge, decouplage. Depend du fichier seul.
    2. **par jour** — Banister. Depend de la veille, donc se deroule en serie.
    3. **par periode** — vitesse critique, endurance, VDOT. Depend d'une
       fenetre glissante d'efforts records.

  La projection se lit au dessus du niveau 3 : c'est la pente de la vitesse
  critique dans le temps.
  """

  import Ecto.Query

  alias Soleus.Analytics.{
    CriticalSpeed,
    DailyLoad,
    Decoupling,
    Endurance,
    Load,
    ModelFit,
    Pace,
    Regression,
    Vdot
  }

  alias Soleus.Repo
  alias Soleus.Training

  # Fenetre d'ajustement des modeles. 90 jours est le compromis d'usage : plus
  # court, le nuage d'efforts records est trop maigre pour ajuster deux
  # parametres ; plus long, on melange deux etats de forme differents et
  # l'ajustement decrit un athlete qui n'existe plus.
  @fit_window_days 90

  # Les distances pour lesquelles on publie une prediction.
  @race_distances [1500.0, 3000.0, 5000.0, 10_000.0, 21_097.5, 42_195.0]

  # Colonnes reecrites par la reconstruction de la serie de charge. La date est
  # la cle du conflit et reste donc en dehors.
  @daily_load_columns [
    :load,
    :distance_m,
    :moving_time_s,
    :activity_count,
    :ctl,
    :atl,
    :tsb,
    :ramp_rate,
    :updated_at
  ]

  def fit_window_days, do: @fit_window_days
  def race_distances, do: @race_distances

  # -- niveau 1 : par seance --------------------------------------------------

  @doc """
  Calcule et enregistre les metriques derivees d'une seance.

  La vitesse critique du moment est passee en argument plutot que relue ici :
  analyser un lot de 500 activites importees ne doit pas refaire la meme
  requete 500 fois.
  """
  @spec analyze_activity(map(), map(), CriticalSpeed.t() | nil) :: {:ok, map()} | {:error, term()}
  def analyze_activity(activity, athlete, cs_fit) do
    series = Training.load_series(activity)

    {load, _source} = Load.score(activity, athlete, cs_fit) || {nil, nil}

    Training.update_metrics(activity, %{
      trimp: Load.trimp(activity, athlete),
      load: load,
      intensity_factor: Load.intensity_factor(activity, cs_fit && cs_fit.cs_ms),
      decoupling: series && Decoupling.compute(series),
      analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  @doc "Analyse toutes les seances en attente, puis recalcule la charge."
  @spec analyze_pending() :: {:ok, non_neg_integer()}
  def analyze_pending do
    athlete = Training.athlete()
    cs_fit = current_cs_fit("run")

    count =
      Training.unanalyzed_activities()
      |> Enum.reduce(0, fn activity, done ->
        case analyze_activity(activity, athlete, cs_fit) do
          {:ok, _} -> done + 1
          _ -> done
        end
      end)

    if count > 0, do: rebuild_daily_loads()

    {:ok, count}
  end

  # -- niveau 2 : par jour ----------------------------------------------------

  @doc """
  Recalcule la serie de charge quotidienne depuis la premiere activite.

  La serie est reconstruite en entier et non mise a jour en place. C'est
  volontaire : les moyennes exponentielles se propagent, donc un import qui
  ajoute une seance d'il y a trois mois invalide tout ce qui suit. Recalculer
  quelques milliers de jours coute quelques millisecondes, la ou une mise a
  jour incrementale serait une source de divergence silencieuse.
  """
  @spec rebuild_daily_loads() :: {:ok, non_neg_integer()} | {:ok, :empty}
  def rebuild_daily_loads do
    case Training.first_activity_date() do
      nil ->
        {:ok, :empty}

      first ->
        today = Date.utc_today()
        totals = Training.daily_totals(first, today) |> Map.new(&{&1.date, &1})

        rows =
          first
          |> Date.range(today)
          # Les jours de repos doivent figurer dans la serie avec une charge
          # nulle. Sans eux, la fatigue aigue ne redescendrait jamais et la
          # forme serait structurellement sous-estimee.
          |> Enum.map(fn date ->
            totals
            |> Map.get(date, %{})
            |> then(
              &%{
                date: date,
                load: to_float(&1[:load]),
                distance_m: to_float(&1[:distance_m]),
                moving_time_s: &1[:moving_time_s] || 0,
                activity_count: &1[:activity_count] || 0
              }
            )
          end)
          |> Load.banister()
          |> Enum.map(fn row ->
            row
            |> Map.put(:inserted_at, timestamp())
            |> Map.put(:updated_at, timestamp())
          end)

        {count, _} =
          Repo.insert_all(DailyLoad, rows,
            on_conflict: {:replace, @daily_load_columns},
            conflict_target: [:date]
          )

        {:ok, count}
    end
  end

  @doc "La serie de charge des `days` derniers jours."
  @spec load_series(pos_integer()) :: [DailyLoad.t()]
  def load_series(days \\ 180) do
    since = Date.add(Date.utc_today(), -days)

    Repo.all(from d in DailyLoad, where: d.date >= ^since, order_by: [asc: d.date])
  end

  @doc "L'etat de forme le plus recent."
  @spec current_form() :: DailyLoad.t() | nil
  def current_form do
    Repo.one(from d in DailyLoad, order_by: [desc: d.date], limit: 1)
  end

  # -- niveau 3 : modeles -----------------------------------------------------

  @doc """
  Ajuste les modeles sur la fenetre glissante et enregistre le resultat.

  Un enregistrement par jour : c'est l'historique de ces ajustements qui rend
  la projection possible, puisque c'est la derive de la vitesse critique qu'on
  extrapole.
  """
  @spec fit_models(String.t(), Date.t()) :: {:ok, ModelFit.t()} | {:error, term()}
  def fit_models(sport \\ "run", on \\ Date.utc_today()) do
    from_date = Date.add(on, -@fit_window_days)
    curve = Training.best_effort_curve(sport, from_date, on)

    cs = CriticalSpeed.fit(curve) |> ok_or_nil()
    endurance = Endurance.fit(curve) |> ok_or_nil()
    {predictions, exponent, source} = predictions(cs, endurance, curve)

    attrs = %{
      fitted_on: on,
      sport: sport,
      window_days: @fit_window_days,
      cs_ms: cs && cs.cs_ms,
      d_prime_m: cs && cs.d_prime_m,
      r2: cs && cs.r2,
      sample_count: length(curve),
      vdot: vdot_from(predictions),
      endurance_exponent: exponent,
      exponent_source: source,
      predictions: predictions
    }

    %ModelFit{}
    |> ModelFit.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :cs_ms,
           :d_prime_m,
           :r2,
           :sample_count,
           :vdot,
           :endurance_exponent,
           :exponent_source,
           :predictions,
           :updated_at
         ]},
      conflict_target: [:fitted_on, :sport, :window_days]
    )
  end

  @doc "Le dernier ajustement enregistre pour un sport."
  @spec current_fit(String.t()) :: ModelFit.t() | nil
  def current_fit(sport \\ "run") do
    Repo.one(
      from f in ModelFit,
        where: f.sport == ^sport and f.window_days == @fit_window_days,
        order_by: [desc: f.fitted_on],
        limit: 1
    )
  end

  @doc "L'historique des ajustements, pour les graphes de progression."
  @spec fit_history(String.t(), pos_integer()) :: [ModelFit.t()]
  def fit_history(sport \\ "run", days \\ 365) do
    since = Date.add(Date.utc_today(), -days)

    Repo.all(
      from f in ModelFit,
        where: f.sport == ^sport and f.window_days == @fit_window_days and f.fitted_on >= ^since,
        where: not is_nil(f.cs_ms),
        order_by: [asc: f.fitted_on]
    )
  end

  defp current_cs_fit(sport) do
    case current_fit(sport) do
      %ModelFit{cs_ms: cs, d_prime_m: d} when is_number(cs) and is_number(d) ->
        %{cs_ms: cs, d_prime_m: d, r2: 1.0, sample_count: 0}

      _ ->
        nil
    end
  end

  # -- predictions ------------------------------------------------------------

  # Au dela de cette duree, le modele a deux parametres devient optimiste : il
  # ignore la fatigue, qui est precisement ce qui domine sur un semi.
  @cs_max_duration 1200

  # Exposant de Riegel publie, mesure sur une population. Le repli quand la
  # courbe de l'athlete ne permet pas d'en ajuster un personnel.
  @literature_exponent 1.06

  # Ecart tolere entre la loi de puissance et le modele de vitesse critique au
  # sommet de la plage ou les deux sont censes concorder.
  @consistency_tolerance 0.03

  @doc """
  Temps predits par distance, en secondes.

  Rend `{predictions, exponent, source}` : l'exposant et son origine comptent
  autant que les temps, puisqu'ils disent si les predictions longues sont
  calees sur l'athlete ou sur une moyenne de population.

  ## Comment le modele est choisi

  Le modele de vitesse critique sert jusqu'a vingt minutes, ou sa linearite est
  etablie. Au dela, on extrapole par Riegel depuis une performance de reference
  prise au sommet de cette plage.

  ## Pourquoi pas la loi de puissance directement

  Parce qu'une courbe de meilleurs efforts tiree de l'entrainement n'est
  maximale que la ou l'athlete a reellement couru fort. Les paliers de deux a
  vingt minutes sont couverts par le fractionne et le seuil ; ceux d'une heure
  ne le sont que par les sorties longues, courues en footing. Ajuster un
  exposant d'endurance sur ces points-la mesure la lenteur des footings, pas
  l'endurance.

  C'est l'erreur qui donnait un 5 000 m predit trois minutes plus lent que ce
  que le modele de vitesse critique annoncait sur la meme base. D'ou le test de
  coherence `consistent?/2` : l'exposant personnel n'est retenu que si les deux
  modeles se rejoignent la ou ils se chevauchent.
  """
  @spec predictions(CriticalSpeed.t() | nil, Endurance.t() | nil, [map()]) ::
          {map(), float(), String.t()}
  def predictions(cs, endurance, curve \\ []) do
    {exponent, source} = endurance_exponent(cs, endurance)

    predictions =
      @race_distances
      |> Enum.map(&{&1, predict_distance(&1, cs, exponent, curve)})
      |> Enum.reject(fn {_d, t} -> is_nil(t) or t <= 0 end)
      |> Map.new(fn {d, t} -> {format_key(d), Float.round(t, 1)} end)

    {predictions, exponent, source}
  end

  defp endurance_exponent(cs, endurance) do
    if cs && endurance && consistent?(cs, endurance) do
      {endurance.riegel_exponent, "personal"}
    else
      {@literature_exponent, "literature"}
    end
  end

  # Les deux modeles sont confrontes a vingt minutes, la seule duree ou ils sont
  # tous les deux dans leur domaine de validite. Un ecart de plus de 3 % sur la
  # vitesse signifie que le haut de la courbe est mou, et que l'exposant
  # ajuste dessus ne decrit pas l'endurance de l'athlete.
  defp consistent?(cs, endurance) do
    with from_cs when is_number(from_cs) <- CriticalSpeed.speed_for(cs, @cs_max_duration),
         distance when is_number(distance) <- power_law_distance(endurance, @cs_max_duration),
         true <- from_cs > 0 do
      abs(distance / @cs_max_duration - from_cs) / from_cs < @consistency_tolerance
    else
      _ -> false
    end
  end

  defp power_law_distance(%{log_a: log_a, b: b}, duration) do
    :math.exp(log_a + b * :math.log(duration))
  end

  defp predict_distance(distance, cs, exponent, curve) do
    cs_estimate = cs && CriticalSpeed.predict(cs, distance)

    cond do
      is_number(cs_estimate) and cs_estimate <= @cs_max_duration -> cs_estimate
      cs -> riegel_from_cs(cs, distance, exponent)
      true -> riegel_fallback(distance, curve)
    end
  end

  # L'ancrage se fait sur la performance que le modele de vitesse critique
  # predit au sommet de sa plage, et non sur un effort brut de la courbe : cette
  # valeur est lissee par l'ajustement, donc moins sensible a une seule seance
  # exceptionnelle ou a un GPS fantaisiste.
  defp riegel_from_cs(cs, distance, exponent) do
    anchor_distance = cs.cs_ms * @cs_max_duration + cs.d_prime_m

    Endurance.riegel(anchor_distance, @cs_max_duration * 1.0, distance, exponent)
  end

  defp riegel_fallback(distance, curve) do
    # Sans aucun ajustement, on s'ancre sur l'effort le plus long disponible :
    # Riegel extrapole mieux vers le haut depuis une base longue que depuis un
    # sprint. C'est le cas du premier import, ou il vaut mieux une estimation
    # grossiere qu'un tableau vide.
    case Enum.max_by(curve, & &1.duration_s, fn -> nil end) do
      nil -> nil
      anchor -> Endurance.riegel(anchor.distance_m, anchor.duration_s, distance)
    end
  end

  defp vdot_from(predictions) do
    # Le VDOT se lit sur le 5 000 m : c'est la distance ou la formule de
    # Daniels est la mieux calee, et la plus souvent couverte a l'entrainement.
    case Map.get(predictions, "5000") do
      time when is_number(time) -> Vdot.from_performance(5000, time)
      _ -> nil
    end
  end

  # -- projection -------------------------------------------------------------

  @doc """
  Projette la progression de la vitesse critique et date un objectif.

  La methode, et ses limites, en clair : on ajuste une droite sur l'historique
  de vitesse critique, on l'extrapole, et on recalcule le temps predit en
  gardant la reserve anaerobie et l'exposant d'endurance a leur valeur
  actuelle. L'intervalle vient de l'ecart-type residuel de cette droite.

  C'est une extrapolation lineaire, donc elle suppose que la progression
  continue au meme rythme. C'est faux a long terme — la progression sature
  toujours — et le resultat doit se lire comme une tendance, pas comme une
  promesse. Au dela de six mois, `horizon_days` cesse d'etre credible et la
  fonction refuse de repondre.
  """
  @spec project(number(), number(), keyword()) :: {:ok, map()} | {:error, atom()}
  def project(distance_m, goal_time_s, opts \\ []) do
    sport = Keyword.get(opts, :sport, "run")
    horizon = Keyword.get(opts, :horizon_days, 180)
    history = fit_history(sport, Keyword.get(opts, :lookback_days, 365))

    with {:ok, trend} <- cs_trend(history),
         %ModelFit{} = latest <- current_fit(sport),
         true <- is_number(latest.d_prime_m) do
      resolve_goal(trend, latest, distance_m, goal_time_s, horizon)
    else
      :error -> {:error, :not_enough_history}
      nil -> {:error, :no_model}
      false -> {:error, :no_model}
      other -> other
    end
  end

  # Au moins six ajustements etales sur quatre semaines. En dessous, la pente
  # se calcule sur du bruit : deux semaines d'affilee avec une seule seance de
  # qualite suffisent a faire croire a une progression fulgurante.
  defp cs_trend(history) when length(history) < 6, do: :error

  defp cs_trend(history) do
    first = hd(history).fitted_on

    if Date.diff(List.last(history).fitted_on, first) < 28 do
      :error
    else
      points = Enum.map(history, &{Date.diff(&1.fitted_on, first) * 1.0, &1.cs_ms})

      case Regression.ols(points) do
        {:ok, reg} -> {:ok, Map.put(reg, :origin, first)}
        :error -> :error
      end
    end
  end

  defp resolve_goal(trend, latest, distance_m, goal_time_s, horizon) do
    today = Date.utc_today()

    # Le jour 0 vaut exactement la vitesse critique du dernier ajustement, et
    # non la valeur que la droite de tendance prend aujourd'hui. La tendance ne
    # sert qu'a fournir la pente.
    #
    # Sans cet ancrage, la droite passe legerement a cote du dernier point et
    # la projection annonce "deja atteint" un objectif que le tableau des
    # predictions, juste a cote, affiche comme non atteint. Deux chiffres qui se
    # contredisent a l'ecran coutent plus cher que la precision theorique
    # gagnee en gardant l'ordonnee de la regression.
    cs_at = fn days -> latest.cs_ms + trend.slope * days end

    # Exactement la meme cascade que `predictions/3`, et non le modele de
    # vitesse critique brut. Les faire diverger est ce qui faisait annoncer
    # "10 km sous 50 minutes deja atteint" pendant que le tableau des
    # predictions affichait 51:14 sur la meme ligne.
    exponent = latest.endurance_exponent || @literature_exponent

    time_at = fn cs ->
      if cs > 0 do
        predict_distance(distance_m, %{cs_ms: cs, d_prime_m: latest.d_prime_m}, exponent, [])
      end
    end

    current = time_at.(cs_at.(0))

    cond do
      is_nil(current) ->
        {:error, :no_model}

      current <= goal_time_s ->
        {:ok,
         built(:already_reached, 0, today, current, trend, cs_at.(0), distance_m, goal_time_s)}

      trend.slope <= 0 ->
        {:error, :no_progression}

      true ->
        first_day_reaching(horizon, cs_at, time_at, goal_time_s)
        |> case do
          nil ->
            {:error, :beyond_horizon}

          days ->
            {:ok,
             built(
               :projected,
               days,
               Date.add(today, days),
               time_at.(cs_at.(days)),
               trend,
               cs_at.(days),
               distance_m,
               goal_time_s
             )}
        end
    end
  end

  # Balayage jour par jour plutot qu'une inversion analytique : la cascade de
  # prediction n'est pas inversible en forme fermee, puisqu'elle change de
  # modele selon la duree obtenue.
  defp first_day_reaching(horizon, cs_at, time_at, goal_time_s) do
    Enum.find(1..horizon, fn day -> time_at.(cs_at.(day)) <= goal_time_s end)
  end

  defp built(status, days, date, predicted, trend, cs, distance_m, goal_time_s) do
    %{
      status: status,
      days: days,
      date: date,
      distance_m: distance_m,
      goal_time_s: goal_time_s,
      predicted_time_s: predicted,
      cs_ms: cs,
      # La pente en m/s par jour est illisible. Ramenee a la semaine et
      # exprimee en secondes d'allure au kilometre, elle devient une phrase :
      # "tu gagnes trois secondes au kilometre par semaine".
      weekly_pace_gain_s: weekly_pace_gain(trend.slope, cs),
      confidence: confidence(trend),
      r2: trend.r2,
      sample_count: trend.n
    }
  end

  defp weekly_pace_gain(slope, cs) when is_number(cs) and cs > 0 do
    Pace.per_km(cs) - Pace.per_km(cs + slope * 7)
  end

  defp weekly_pace_gain(_slope, _cs), do: nil

  # L'ecart-type residuel de la droite, rapporte a la vitesse critique. Plus la
  # serie est dispersee autour de sa tendance, moins la date projetee vaut.
  defp confidence(%{residual_sd: nil}), do: :low

  defp confidence(%{residual_sd: sd, r2: r2}) do
    cond do
      r2 > 0.8 and sd < 0.05 -> :high
      r2 > 0.5 -> :medium
      true -> :low
    end
  end

  @doc """
  Objectifs ronds juste sous les performances actuellement predites, dates.

  Plutot que de demander a l'athlete de saisir un objectif pour decouvrir une
  date, on prend le prochain palier rond de chaque distance et on le date
  directement. "Dix kilometres sous cinquante minutes" est la question que les
  gens se posent vraiment, et elle se deduit des predictions.
  """
  @spec next_goals(String.t()) :: [map()]
  def next_goals(sport \\ "run") do
    case current_fit(sport) do
      %ModelFit{predictions: predictions} when map_size(predictions) > 0 ->
        predictions
        |> Enum.sort_by(fn {d, _} -> String.to_integer(d) end)
        |> Enum.map(fn {distance, predicted} ->
          target = round_down(predicted)

          {String.to_integer(distance) * 1.0, target,
           project(String.to_integer(distance) * 1.0, target, sport: sport)}
        end)
        |> Enum.map(fn {distance, target, result} ->
          %{distance_m: distance, goal_time_s: target, result: result}
        end)

      _ ->
        []
    end
  end

  # Paliers ronds, cales sur la facon dont les coureurs parlent : la demi-minute
  # sur un 5 000 m, la minute sur un 10 km, cinq minutes sur un semi. Un
  # objectif a 51:07 ne veut rien dire pour personne, mais un palier trop large
  # non plus : viser 20:00 quand on predit 24:34 n'est pas un objectif, c'est
  # une autre saison.
  defp round_down(seconds) do
    step =
      cond do
        seconds < 1200 -> 30
        seconds < 3600 -> 60
        seconds < 7200 -> 300
        true -> 600
      end

    floor(seconds / step) * step * 1.0
  end

  @doc "Raison lisible d'une projection impossible."
  def explain_error(:not_enough_history),
    do: "Pas encore assez d'historique — il faut environ un mois d'ajustements."

  def explain_error(:no_model), do: "Les modeles ne sont pas encore ajustes."
  def explain_error(:no_progression), do: "Aucune progression mesurable sur la periode."
  def explain_error(:beyond_horizon), do: "L'objectif est hors de portee a six mois."
  def explain_error(_other), do: "Projection indisponible."

  # -- assemblage pour l'interface ---------------------------------------------

  @doc """
  Rassemble en une passe tout ce qu'affiche le tableau de bord.

  Regroupe ici plutot que dans la vue : une dizaine de requetes dispersees dans
  un `mount` rendrait impossible de voir ce que coute l'affichage, et la vue
  n'a pas a connaitre la forme du schema.
  """
  @spec dashboard(String.t()) :: map()
  def dashboard(sport \\ "run") do
    today = Date.utc_today()
    fit = current_fit(sport)

    %{
      sport: sport,
      today: today,
      form: current_form(),
      load_days: load_series(180),
      fit: fit,
      cs: cs_of(fit),
      fits: fit_history(sport, 365),
      curve: Training.best_effort_curve(sport, Date.add(today, -@fit_window_days), today),
      bests: Training.personal_bests(sport),
      recent: Training.list_activities(sport: sport, limit: 40),
      goals: next_goals(sport),
      weeks: week_summary(),
      paces: fit && fit.vdot && Vdot.training_speeds(fit.vdot)
    }
  end

  @doc "Volume des deux dernieres semaines, pour les comparer."
  @spec week_summary() :: %{current: map(), previous: map()}
  def week_summary do
    today = Date.utc_today()
    # Lundi de la semaine en cours : `day_of_week/1` rend 1 pour lundi.
    monday = Date.add(today, -(Date.day_of_week(today) - 1))

    %{
      current: totals_between(monday, today),
      previous: totals_between(Date.add(monday, -7), Date.add(monday, -1))
    }
  end

  defp totals_between(from, to) do
    Repo.one(
      from d in DailyLoad,
        where: d.date >= ^from and d.date <= ^to,
        select: %{
          distance_m: coalesce(sum(d.distance_m), 0.0),
          moving_time_s: coalesce(sum(d.moving_time_s), 0),
          load: coalesce(sum(d.load), 0.0),
          activity_count: coalesce(sum(d.activity_count), 0)
        }
    ) || %{distance_m: 0.0, moving_time_s: 0, load: 0.0, activity_count: 0}
  end

  defp cs_of(%ModelFit{cs_ms: cs, d_prime_m: d, r2: r2}) when is_number(cs) and is_number(d),
    do: %{cs_ms: cs, d_prime_m: d, r2: r2 || 1.0, sample_count: 0}

  defp cs_of(_fit), do: nil

  # -- utilitaires ------------------------------------------------------------

  defp ok_or_nil({:ok, value}), do: value
  defp ok_or_nil(_), do: nil

  defp to_float(nil), do: 0.0
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n * 1.0

  defp format_key(distance), do: distance |> round() |> Integer.to_string()

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
