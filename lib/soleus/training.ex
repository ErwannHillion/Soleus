defmodule Soleus.Training do
  @moduledoc """
  Les seances : ingestion, lecture, et les efforts records qui en decoulent.

  Ce contexte ne calcule aucune metrique physiologique — il en stocke le
  resultat. Les modeles vivent dans `Soleus.Analytics`, qui depend de celui-ci
  et jamais l'inverse.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Soleus.Analytics.MeanMaximal
  alias Soleus.Ingest.Fit
  alias Soleus.Repo
  alias Soleus.Training.{Activity, Athlete, BestEffort, Lap, Stream}

  # -- ingestion --------------------------------------------------------------

  @doc """
  Importe un fichier FIT.

  L'operation est idempotente : l'empreinte du fichier sert de cle, donc
  reimporter le meme export ne cree pas de doublon. Rend
  `{:ok, :already_imported, activity}` dans ce cas, et non une erreur — passer
  deux fois sur un dossier est un geste normal, pas un incident.
  """
  @spec import_fit(Path.t(), keyword()) ::
          {:ok, :imported | :already_imported, Activity.t()} | {:error, term()}
  def import_fit(path, opts \\ []) do
    case Fit.decode(path) do
      {:ok, decoded} -> import_decoded(decoded, path, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp import_decoded(decoded, path, opts) do
    case Repo.get_by(Activity, fit_digest: decoded.digest) do
      %Activity{} = existing -> {:ok, :already_imported, existing}
      nil -> persist(decoded, path, opts)
    end
  end

  defp persist(decoded, path, opts) do
    attrs =
      decoded
      |> Map.take([
        :sport,
        :started_at,
        :distance_m,
        :moving_time_s,
        :elapsed_time_s,
        :elevation_gain_m,
        :calories,
        :avg_hr,
        :max_hr,
        :avg_cadence,
        :avg_speed_ms,
        :max_speed_ms
      ])
      |> Map.merge(%{
        source: "fit_import",
        fit_digest: decoded.digest,
        fit_path: path,
        name: Keyword.get(opts, :name)
      })

    # Une transaction unique : une activite sans ses series ni ses efforts
    # records serait invisible du tableau de bord tout en bloquant le
    # reimport, puisque son empreinte serait deja prise.
    Multi.new()
    |> Multi.insert(:activity, Activity.ingest_changeset(%Activity{}, attrs))
    |> Multi.insert(:stream, fn %{activity: activity} ->
      Stream.changeset(%Stream{}, %{activity_id: activity.id, series: decoded.series})
    end)
    |> Multi.run(:best_efforts, fn _repo, %{activity: activity} ->
      {:ok, insert_best_efforts(activity, decoded.series)}
    end)
    |> Multi.run(:laps, fn _repo, %{activity: activity} ->
      {:ok, insert_laps(activity, decoded[:laps] || [])}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{activity: activity}} -> {:ok, :imported, activity}
      {:error, _step, reason, _done} -> {:error, reason}
    end
  end

  @doc """
  Calcule et enregistre les efforts records d'une activite.

  Appele a l'ingestion, et reappelable seul si les paliers changent.
  """
  @spec insert_best_efforts(Activity.t(), map()) :: non_neg_integer()
  def insert_best_efforts(%Activity{} = activity, series) do
    grid = MeanMaximal.grid(series)

    rows =
      for {kind, efforts} <- [
            {"duration", MeanMaximal.by_duration(grid)},
            {"distance", MeanMaximal.by_distance(grid)}
          ],
          effort <- efforts do
        effort
        |> Map.merge(%{
          activity_id: activity.id,
          kind: kind,
          started_at: activity.started_at
        })
        |> then(&BestEffort.changeset(%BestEffort{}, &1))
        |> then(&Ecto.Changeset.apply_action!(&1, :insert))
        |> Map.take([
          :activity_id,
          :kind,
          :duration_s,
          :distance_m,
          :speed_ms,
          :avg_hr,
          :started_at
        ])
        |> Map.merge(%{inserted_at: timestamp(), updated_at: timestamp()})
      end

    {count, _} = Repo.insert_all(BestEffort, rows, on_conflict: :nothing)
    count
  end

  @doc """
  Enregistre les tours d'une seance.

  Reappelable : les tours existants sont remplaces. C'est ce qui permet de
  rattraper un historique importe avant que les tours soient lus, sans
  reimporter les fichiers.
  """
  @spec insert_laps(Activity.t(), [map()]) :: non_neg_integer()
  def insert_laps(%Activity{} = activity, laps) do
    Repo.delete_all(from l in Lap, where: l.activity_id == ^activity.id)

    rows =
      laps
      |> Enum.map(fn lap ->
        lap
        |> Map.put(:activity_id, activity.id)
        |> Map.take(Lap.fields())
        |> Map.merge(%{inserted_at: timestamp(), updated_at: timestamp()})
      end)
      |> Enum.reject(&is_nil(&1[:index]))

    {count, _} = Repo.insert_all(Lap, rows)
    count
  end

  @doc """
  Remplace les series d'une seance.

  Sert au rattrapage : quand le decodeur apprend a lire une nouvelle mesure,
  les seances deja en base ne la portent pas. Relire le fichier et remplacer
  le bloc coute moins cher qu'un reimport complet, et ne touche ni aux
  metriques calculees ni aux efforts records.
  """
  @spec replace_series(Activity.t(), map()) :: :ok
  def replace_series(%Activity{id: id}, series) do
    Repo.delete_all(from s in Stream, where: s.activity_id == ^id)

    %Stream{}
    |> Stream.changeset(%{activity_id: id, series: series})
    |> Repo.insert!()

    :ok
  end

  @doc "Les tours d'une seance, dans l'ordre."
  @spec laps(Activity.t() | integer()) :: [Lap.t()]
  def laps(%Activity{id: id}), do: laps(id)

  def laps(activity_id) when is_integer(activity_id) do
    Repo.all(from l in Lap, where: l.activity_id == ^activity_id, order_by: [asc: l.index])
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # -- lecture ----------------------------------------------------------------

  @doc """
  Applique a une seance le resume que Garmin en donne.

  Deux informations n'existent que la : le **nom** affiche dans Connect, et le
  **temps passe dans chaque zone** de frequence cardiaque. Le fichier FIT ne
  contient que des mesures.

  Partage entre l'import d'un export RGPD et la synchronisation par l'API :
  les deux recoivent le meme objet, puisqu'il vient du meme backend.

  Les champs absents ne sont pas ecrits. Un resume incomplet ne doit pas
  effacer ce qu'un passage precedent avait pose.
  """
  @spec apply_summary(Activity.t() | integer(), map()) :: :ok
  def apply_summary(%Activity{id: id}, summary), do: apply_summary(id, summary)

  def apply_summary(id, summary) when is_integer(id) do
    activity = Repo.get(Activity, id)

    attrs =
      summary
      |> summary_attrs(activity)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    if attrs != [] do
      from(a in Activity, where: a.id == ^id) |> Repo.update_all(set: attrs)
    end

    :ok
  end

  # Tout ce que le resume apporte et que le fichier FIT ne porte pas, ou porte
  # moins commodement. Les altitudes sont en centimetres dans le resume, la
  # ou le reste de Soleus compte en metres.
  defp summary_attrs(summary, activity) do
    %{
      name: summary["activityName"] || summary["name"],
      notes: summary["locationName"],
      hr_zone_s: zone_seconds(summary),
      power_zone_s: power_zone_seconds(summary),
      grade_adjusted_speed_ms: grade_adjusted(summary, activity),
      min_hr: round_or_nil(summary["minHr"]),
      steps: round_or_nil(summary["steps"]),
      min_elevation_m: centimetres(summary["minElevation"]),
      max_elevation_m: centimetres(summary["maxElevation"]),
      garmin_load: summary["activityTrainingLoad"],
      vo2max: summary["vO2MaxValue"],
      training_effect_label: summary["trainingEffectLabel"],
      intensity_moderate_min: round_or_nil(summary["moderateIntensityMinutes"]),
      intensity_vigorous_min: round_or_nil(summary["vigorousIntensityMinutes"]),
      body_battery_delta: round_or_nil(summary["differenceBodyBattery"]),
      bmr_calories: round_or_nil(summary["bmrCalories"]),
      water_ml: round_or_nil(summary["waterEstimated"])
    }
  end

  @doc """
  Temps par zone de puissance, en secondes.

  Six compartiments, de la zone 0 a la zone 5, la ou les zones cardiaques en
  ont sept. Garmin n'ajoute pas de compartiment « au dela » pour la
  puissance.
  """
  @spec power_zone_seconds(map()) :: [non_neg_integer()] | nil
  def power_zone_seconds(summary) do
    buckets = Enum.map(0..5, &summary["powerTimeInZone_#{&1}"])

    if Enum.any?(buckets, &is_number/1) do
      Enum.map(buckets, fn value -> round((value || 0) / 1000) end)
    end
  end

  # La vitesse corrigee de la pente, ramenee en m/s.
  #
  # Le resume n'emploie pas la meme echelle que le fichier FIT pour les
  # vitesses : une sortie a 2,83 m/s y figure a 0,283. Plutot que de coder en
  # dur un facteur dix qui n'est documente nulle part, on passe par le
  # **rapport** entre la vitesse corrigee et la vitesse brute du meme resume.
  # Ce rapport est sans unite, donc insensible a la convention employee, et on
  # l'applique a la vitesse du fichier FIT, qui est en m/s de facon certaine.
  #
  # Deux conditions avant d'accepter la valeur.
  #
  # La premiere est qu'il y ait un **denivele enregistre**. Sans altimetre
  # actif, Garmin renseigne quand meme le champ, mais avec une valeur qui ne
  # veut rien dire : sur cet historique, les sorties a denivele nul portent
  # des rapports de 0,68 ou 0,90, soit une correction de pente de trente pour
  # cent sur du plat. Les sorties avec denivele, elles, donnent 1,008.
  #
  # La seconde est un garde-fou sur le rapport lui-meme : une correction de
  # pente ne change pas une allure du simple au double.
  defp grade_adjusted(summary, %Activity{avg_speed_ms: speed}) when is_number(speed) do
    with gain when is_number(gain) and gain > 0 <- summary["elevationGain"],
         raw when is_number(raw) and raw > 0 <- summary["avgSpeed"],
         adjusted when is_number(adjusted) <- summary["avgGradeAdjustedSpeed"],
         ratio = adjusted / raw,
         true <- ratio >= 0.85 and ratio <= 1.2 do
      speed * ratio
    else
      _implausible -> nil
    end
  end

  defp grade_adjusted(_summary, _activity), do: nil

  defp centimetres(nil), do: nil
  defp centimetres(value) when is_number(value), do: value / 100

  defp round_or_nil(nil), do: nil
  defp round_or_nil(value) when is_number(value), do: round(value)
  defp round_or_nil(_other), do: nil

  @doc """
  Temps par zone, en secondes, depuis un resume Garmin.

  Garmin publie sept compartiments, de `hrTimeInZone_0` — sous la zone 1 — a
  `hrTimeInZone_6`. Le septieme est au dessus de la zone 5 et vaut zero sur
  tous les exports observes ; on le replie dans la zone 5 plutot que de
  trainer une zone fantome dans toute l'interface.

  Les valeurs sont en **millisecondes**, alors que tout le reste de Soleus
  compte en secondes.
  """
  @spec zone_seconds(map()) :: [non_neg_integer()] | nil
  def zone_seconds(summary) do
    buckets = Enum.map(0..6, &summary["hrTimeInZone_#{&1}"])

    if Enum.any?(buckets, &is_number/1) do
      values = Enum.map(buckets, fn value -> round((value || 0) / 1000) end)
      {main, [above]} = Enum.split(values, 6)
      List.update_at(main, 5, &(&1 + above))
    end
  end

  @doc """
  Les activites les plus recentes, sans leurs series.

  Options : `:sport` (ou `nil` pour tous), `:since`, `:limit`.
  """
  def list_activities(opts \\ []) do
    Activity
    |> order_by(desc: :started_at)
    |> limit(^Keyword.get(opts, :limit, 50))
    |> maybe_sport(Keyword.get(opts, :sport))
    |> maybe_since(Keyword.get(opts, :since))
    |> Repo.all()
  end

  def get_activity!(id), do: Repo.get!(Activity, id)

  @doc "Charge les series d'une activite, decompressees."
  @spec load_series(Activity.t() | integer()) :: map() | nil
  def load_series(%Activity{id: id}), do: load_series(id)

  def load_series(activity_id) when is_integer(activity_id) do
    case Repo.get_by(Stream, activity_id: activity_id) do
      nil -> nil
      stream -> Stream.decode(stream)
    end
  end

  @doc """
  Meilleur effort par palier sur une fenetre glissante.

  C'est l'entree de l'ajustement des modeles : pour chaque duree, la vitesse
  la plus elevee atteinte sur la periode, toutes seances confondues.
  """
  @spec best_effort_curve(String.t(), Date.t(), Date.t(), String.t()) :: [map()]
  def best_effort_curve(sport, from, to, kind \\ "duration") do
    key = if kind == "duration", do: :duration_s, else: :distance_m

    from(e in BestEffort,
      join: a in Activity,
      on: a.id == e.activity_id,
      where: e.kind == ^kind and a.sport == ^sport,
      where: a.local_date >= ^from and a.local_date <= ^to,
      group_by: field(e, ^key),
      select: %{
        duration_s: min(e.duration_s),
        distance_m: max(e.distance_m),
        speed_ms: max(e.speed_ms)
      },
      order_by: [asc: field(e, ^key)]
    )
    |> Repo.all()
  end

  @doc """
  Records personnels toutes periodes confondues, par distance de course.

  Rend la ligne complete et l'activite qui la detient, pour pouvoir cliquer
  dessus depuis le tableau de bord.
  """
  @spec personal_bests(String.t()) :: [map()]
  def personal_bests(sport \\ "run") do
    ranked =
      from(e in BestEffort,
        join: a in Activity,
        on: a.id == e.activity_id,
        where: e.kind == "distance" and a.sport == ^sport,
        select: %{
          distance_m: e.distance_m,
          duration_s: e.duration_s,
          speed_ms: e.speed_ms,
          avg_hr: e.avg_hr,
          activity_id: e.activity_id,
          activity_name: a.name,
          started_at: e.started_at,
          rank: row_number() |> over(partition_by: e.distance_m, order_by: [asc: e.duration_s])
        }
      )

    from(r in subquery(ranked), where: r.rank == 1, order_by: [asc: r.distance_m])
    |> Repo.all()
  end

  @doc "Totaux par jour, pour l'agregation de charge."
  @spec daily_totals(Date.t(), Date.t()) :: [map()]
  def daily_totals(from, to) do
    from(a in Activity,
      where: a.local_date >= ^from and a.local_date <= ^to,
      group_by: a.local_date,
      select: %{
        date: a.local_date,
        load: sum(a.load),
        distance_m: sum(a.distance_m),
        moving_time_s: sum(a.moving_time_s),
        activity_count: count(a.id)
      },
      order_by: [asc: a.local_date]
    )
    |> Repo.all()
  end

  @doc """
  Les sports reellement presents en base, avec leur nombre de seances.

  Sert a construire le filtre de la liste : proposer « natation » a quelqu'un
  qui n'a jamais nage est une case qui ne renverra jamais rien.
  """
  @spec sports_present() :: [{String.t(), non_neg_integer()}]
  def sports_present do
    Repo.all(
      from a in Activity,
        group_by: a.sport,
        order_by: [desc: count(a.id)],
        select: {a.sport, count(a.id)}
    )
  end

  @doc """
  Temps cumule par zone de frequence cardiaque sur une periode.

  Rend une liste de six durees en secondes, de la zone 0 — sous la premiere
  zone — a la zone 5. Les seances sans zones sont ignorees plutot que
  comptees comme du temps en zone 0 : une montre sans ceinture ne veut pas
  dire une heure passee au repos.
  """
  @spec zone_distribution(String.t(), Date.t(), Date.t()) :: [non_neg_integer()]
  def zone_distribution(sport, from, to) do
    from(a in Activity,
      where: a.sport == ^sport and a.local_date >= ^from and a.local_date <= ^to,
      where: not is_nil(a.hr_zone_s),
      select: a.hr_zone_s
    )
    |> Repo.all()
    |> sum_zones()
  end

  defp sum_zones([]), do: List.duplicate(0, 6)

  defp sum_zones(rows) do
    Enum.reduce(rows, List.duplicate(0, 6), fn zones, acc ->
      zones
      |> Enum.zip(acc)
      |> Enum.map(fn {a, b} -> (a || 0) + b end)
      |> Enum.take(6)
    end)
  end

  @doc """
  Nombre de jours depuis la derniere seance de qualite.

  « Qualite » se lit sur le temps passe au dessus de la zone 2 : plus de dix
  minutes en zones 3 a 5. Le critere porte sur l'intensite reellement
  soutenue, et non sur le nom de la seance — un fractionne annule au bout de
  deux series reste nomme « fractionne ».
  """
  @spec days_since_quality(String.t()) :: non_neg_integer() | nil
  def days_since_quality(sport \\ "run") do
    from(a in Activity,
      where: a.sport == ^sport and not is_nil(a.hr_zone_s),
      order_by: [desc: a.local_date],
      limit: 60,
      select: {a.local_date, a.hr_zone_s}
    )
    |> Repo.all()
    |> Enum.find(fn {_date, zones} -> hard_seconds(zones) > 600 end)
    |> case do
      {date, _zones} -> Date.diff(Date.utc_today(), date)
      nil -> nil
    end
  end

  @doc "Secondes passees en zones 3 a 5."
  @spec hard_seconds([integer()] | nil) :: non_neg_integer()
  def hard_seconds(nil), do: 0
  def hard_seconds(zones), do: zones |> Enum.drop(3) |> Enum.sum()

  @doc "Secondes passees en zones 0 a 2."
  @spec easy_seconds([integer()] | nil) :: non_neg_integer()
  def easy_seconds(nil), do: 0
  def easy_seconds(zones), do: zones |> Enum.take(3) |> Enum.sum()

  @doc "La date de la premiere activite connue, ou nil si la base est vide."
  def first_activity_date do
    Repo.one(from a in Activity, select: min(a.local_date))
  end

  @doc "Les activites qui n'ont pas encore ete analysees."
  def unanalyzed_activities do
    Repo.all(from a in Activity, where: is_nil(a.analyzed_at), order_by: [asc: a.started_at])
  end

  def update_metrics(%Activity{} = activity, attrs) do
    activity
    |> Activity.metrics_changeset(attrs)
    |> Repo.update()
  end

  defp maybe_sport(query, nil), do: query
  defp maybe_sport(query, sport), do: where(query, [a], a.sport == ^sport)

  defp maybe_since(query, nil), do: query
  defp maybe_since(query, %Date{} = since), do: where(query, [a], a.local_date >= ^since)

  # -- athlete ----------------------------------------------------------------

  @doc """
  L'athlete, avec ses reperes cardiaques completes depuis l'historique.

  La FC max observee sur l'ensemble des seances est une meilleure estimation
  que `220 - age`, qui a une erreur type de plus de dix battements. La valeur
  saisie a la main reste prioritaire quand elle existe.
  """
  @spec athlete() :: Athlete.t()
  def athlete do
    athlete = Repo.get!(Athlete, 1)

    %{
      athlete
      | hr_max: athlete.hr_max || observed_hr_max(),
        hr_rest: athlete.hr_rest || 50
    }
  end

  def update_athlete(attrs) do
    Repo.get!(Athlete, 1)
    |> Athlete.changeset(attrs)
    |> Repo.update()
  end

  defp observed_hr_max do
    Repo.one(from a in Activity, select: max(a.max_hr))
  end
end
