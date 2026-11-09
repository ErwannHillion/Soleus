defmodule Soleus.Ingest.Wellness do
  @moduledoc """
  Lit les donnees de sante quotidiennes d'un export RGPD Garmin.

  Huit familles de fichiers decrivent la meme journee sous des angles
  differents, chacune avec sa propre structure et son propre decoupage en
  tranches de trois mois :

  | Fichier | Apporte |
  | --- | --- |
  | `UDSFile` | pas, calories, FC repos, stress, reserve d'energie, respiration |
  | `*_sleepData` | duree et phases de sommeil, scores |
  | `*_healthStatusData` | HRV, FC, SpO2, temperature cutanee **avec leurs lignes de base** |
  | `TrainingReadinessDTO` | etat de forme du jour selon Garmin, temps de recuperation |
  | `MetricsAcuteTrainingLoad` | charge aigue et chronique de Garmin |
  | `MetricsMaxMetData` | VO2max estimee |
  | `EnduranceScore` | score d'endurance |
  | `HillScore` | score en cote |
  | `TrainingHistory` | statut d'entrainement |

  La strategie est donc : un reducteur par famille, chacun produisant une map
  `date -> attributs`, puis une fusion. Aucune famille n'est obligatoire —
  l'export d'une montre d'entree de gamme n'en contient que la moitie, et
  l'absence d'un fichier ne doit pas faire echouer l'import des autres.
  """

  alias Soleus.Health.DailyWellness
  alias Soleus.Repo

  # Les familles de donnees, et l'extracteur qui sait lire chacune. La table
  # est publique parce que l'API personnelle Garmin sert **les memes champs**
  # que l'export : meme backend, meme nommage. Seule l'enveloppe change, ce
  # qui permet de partager toute la traduction entre les deux sources.
  @families [
    :daily_summary,
    :sleep,
    :health_status,
    :readiness,
    :acute_load,
    :vo2max,
    :endurance,
    :hill,
    :training_status
  ]

  @doc """
  Importe toutes les familles trouvees sous `dir` et rend le nombre de jours.

  `dir` est la racine `DI_CONNECT` de l'export.
  """
  @spec import(Path.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def import(dir) do
    days =
      %{}
      |> merge_family(dir, "DI-Connect-Aggregator/UDSFile_*.json", :daily_summary)
      |> merge_family(dir, "DI-Connect-Wellness/*_sleepData.json", :sleep)
      |> merge_family(dir, "DI-Connect-Wellness/*_healthStatusData.json", :health_status)
      |> merge_family(dir, "DI-Connect-Metrics/TrainingReadinessDTO_*.json", :readiness)
      |> merge_family(dir, "DI-Connect-Metrics/MetricsAcuteTrainingLoad_*.json", :acute_load)
      |> merge_family(dir, "DI-Connect-Metrics/MetricsMaxMetData_*.json", :vo2max)
      |> merge_family(dir, "DI-Connect-Metrics/EnduranceScore_*.json", :endurance)
      |> merge_family(dir, "DI-Connect-Metrics/HillScore_*.json", :hill)
      |> merge_family(dir, "DI-Connect-Metrics/TrainingHistory_*.json", :training_status)

    if map_size(days) == 0 do
      {:error, :no_wellness_files}
    else
      {:ok, upsert(days)}
    end
  end

  # -- lecture ----------------------------------------------------------------

  @doc "Les familles reconnues."
  def families, do: @families

  @doc """
  Fusionne des enregistrements bruts dans un accumulateur `date -> attributs`.

  Le point d'entree partage entre l'import de fichiers et la synchronisation
  par l'API : les deux produisent les memes enregistrements, seule la facon
  de les obtenir differe.
  """
  @spec merge_records(map(), atom(), list()) :: map()
  def merge_records(acc, family, records) do
    Enum.reduce(records, acc, fn record, days ->
      case extract(record, extractor_for(family)) do
        {date, attrs} when map_size(attrs) > 0 ->
          Map.update(days, date, attrs, &Map.merge(&1, attrs))

        _nothing ->
          days
      end
    end)
  end

  @doc """
  Normalise une reponse JSON en liste d'enregistrements.

  Les reponses de l'API ne sont pas toutes de la meme forme : certaines
  rendent une liste, d'autres un objet unique, d'autres encore un objet qui
  enveloppe une liste sous une cle variable. On accepte les trois plutot que
  d'en supposer une.
  """
  @spec records(term()) :: [map()]
  def records(list) when is_list(list), do: Enum.filter(list, &is_map/1)

  def records(%{} = map) do
    cond do
      Map.has_key?(map, "calendarDate") -> [map]
      inner = Enum.find_value(map, &wrapped_list/1) -> records(inner)
      true -> []
    end
  end

  def records(_other), do: []

  defp wrapped_list({_key, value}) when is_list(value), do: value
  defp wrapped_list(_pair), do: nil

  defp extractor_for(:daily_summary), do: &daily_summary/1
  defp extractor_for(:sleep), do: &sleep/1
  defp extractor_for(:health_status), do: &health_status/1
  defp extractor_for(:readiness), do: &readiness/1
  defp extractor_for(:acute_load), do: &acute_load/1
  defp extractor_for(:vo2max), do: &vo2max/1
  defp extractor_for(:endurance), do: &endurance/1
  defp extractor_for(:hill), do: &hill/1
  defp extractor_for(:training_status), do: &training_status/1

  defp merge_family(acc, dir, pattern, family) do
    dir
    |> Path.join(pattern)
    |> Path.wildcard()
    |> Enum.flat_map(&(&1 |> File.read!() |> Jason.decode!() |> records()))
    |> then(&merge_records(acc, family, &1))
  end

  # Une famille mal formee ne doit pas interrompre l'import des autres : un
  # export couvre plus d'un an et plusieurs modeles de montre, et un seul
  # enregistrement exotique ne vaut pas de tout perdre.
  defp extract(record, extractor) do
    with date when not is_nil(date) <- date_of(record),
         attrs when is_map(attrs) <- extractor.(record) do
      {date, attrs |> drop_nils() |> Map.put(:date, date)}
    else
      _error -> nil
    end
  rescue
    _error -> nil
  end

  # Garmin n'est pas coherent avec son propre export : `calendarDate` est une
  # chaine ISO dans les fichiers de sante, et un entier en millisecondes depuis
  # l'epoque dans ceux de charge d'entrainement, d'endurance et de cote.
  #
  # Ne traiter que la chaine faisait importer zero jour pour ces trois
  # familles, sans la moindre erreur — elles etaient simplement ignorees.
  defp date_of(%{"calendarDate" => raw}) when is_binary(raw) do
    case Date.from_iso8601(raw) do
      {:ok, date} -> date
      _error -> nil
    end
  end

  defp date_of(%{"calendarDate" => raw}) when is_number(raw) do
    raw
    |> round()
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_date()
  end

  defp date_of(_record), do: nil

  # -- extracteurs ------------------------------------------------------------

  defp daily_summary(r) do
    stress = r |> get_in(["allDayStress", "aggregatorList"]) |> total_aggregate()
    battery = r["bodyBattery"] || %{}
    respiration = r["respiration"] || %{}

    %{
      resting_hr: int(r["restingHeartRate"]),
      steps: int(r["totalSteps"]),
      steps_goal: int(r["dailyStepGoal"]),
      floors: num(r["floorsAscendedInMeters"]),
      active_seconds: int(r["activeSeconds"]),
      calories_total: int(r["totalKilocalories"]),
      calories_active: int(r["activeKilocalories"]),
      intensity_moderate_min: int(r["moderateIntensityMinutes"]),
      intensity_vigorous_min: int(r["vigorousIntensityMinutes"]),
      distance_m: num(r["totalDistanceMeters"]),
      respiration_avg: num(respiration["avgWakingRespirationValue"]),
      respiration_low: num(respiration["lowestRespirationValue"]),
      respiration_high: num(respiration["highestRespirationValue"]),
      body_battery_charged: int(battery["chargedValue"]),
      body_battery_drained: int(battery["drainedValue"]),
      body_battery_high: battery |> battery_stat("HIGHEST") |> int(),
      body_battery_low: battery |> battery_stat("LOWEST") |> int(),
      stress_avg: int(stress["averageStressLevel"]),
      stress_max: int(stress["maxStressLevel"]),
      stress_rest_s: int(stress["restDuration"])
    }
  end

  # La liste des agregats de stress contient un total et des tranches horaires.
  # Seul le total nous interesse.
  defp total_aggregate(list) when is_list(list) do
    Enum.find(list, %{}, &(&1["type"] == "TOTAL"))
  end

  defp total_aggregate(_other), do: %{}

  defp battery_stat(%{"bodyBatteryStatList" => list}, type) when is_list(list) do
    list |> Enum.find(%{}, &(&1["bodyBatteryStatType"] == type)) |> Map.get("statsValue")
  end

  defp battery_stat(_battery, _type), do: nil

  defp sleep(r) do
    scores = r["sleepScores"] || %{}

    %{
      sleep_total_s: sleep_total(r),
      sleep_deep_s: int(r["deepSleepSeconds"]),
      sleep_light_s: int(r["lightSleepSeconds"]),
      sleep_rem_s: int(r["remSleepSeconds"]),
      sleep_awake_s: int(r["awakeSleepSeconds"]),
      sleep_score: int(scores["overallScore"]),
      sleep_quality_score: int(scores["qualityScore"]),
      sleep_recovery_score: int(scores["recoveryScore"]),
      sleep_start: timestamp(r["sleepStartTimestampGMT"]),
      sleep_end: timestamp(r["sleepEndTimestampGMT"])
    }
  end

  # Le temps de sommeil est la somme des phases, sans l'eveil : Garmin ne
  # publie pas de total, et la difference entre les bornes de la fenetre
  # inclurait les reveils nocturnes.
  defp sleep_total(r) do
    ["deepSleepSeconds", "lightSleepSeconds", "remSleepSeconds"]
    |> Enum.map(&int(r[&1]))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      phases -> Enum.sum(phases)
    end
  end

  # Les lignes de base arrivent sous forme de liste typee, une entree par
  # mesure. On les ramene a plat, parce qu'une colonne par mesure se lit et
  # s'interroge infiniment mieux qu'un tableau a parcourir.
  defp health_status(%{"metrics" => metrics}) when is_list(metrics) do
    Enum.reduce(metrics, %{}, fn metric, acc ->
      case metric["type"] do
        "HRV" ->
          Map.merge(acc, %{
            hrv_overnight: positive(metric["value"]),
            hrv_baseline_low: positive(metric["baselineLowerLimit"]),
            hrv_baseline_high: positive(metric["baselineUpperLimit"]),
            hrv_status: status(metric["status"])
          })

        "HR" ->
          Map.merge(acc, %{
            hr_baseline_low: metric["baselineLowerLimit"] |> positive() |> int(),
            hr_baseline_high: metric["baselineUpperLimit"] |> positive() |> int(),
            hr_status: status(metric["status"])
          })

        "SPO2" ->
          Map.merge(acc, %{
            spo2_avg: positive(metric["value"]),
            spo2_status: status(metric["status"])
          })

        "SKIN_TEMP_C" ->
          Map.merge(acc, %{
            skin_temp_delta: num(metric["value"]),
            skin_temp_status: status(metric["status"])
          })

        _other ->
          acc
      end
    end)
  end

  defp health_status(_record), do: %{}

  defp readiness(r) do
    %{
      training_readiness: int(r["score"]),
      recovery_time_h: num(r["recoveryTime"]) |> minutes_to_hours(),
      hrv_weekly_avg: num(r["hrvWeeklyAverage"])
    }
  end

  defp acute_load(r) do
    %{
      garmin_acute_load: num(r["dailyTrainingLoadAcute"]),
      garmin_chronic_load: num(r["dailyTrainingLoadChronic"]),
      garmin_acwr: num(r["dailyAcuteChronicWorkloadRatio"]),
      garmin_acwr_status: status(r["acwrStatus"])
    }
  end

  defp vo2max(r) do
    value =
      r["vo2MaxPreciseValue"] || r["vo2MaxValue"] ||
        get_in(r, ["generic", "vo2MaxPreciseValue"]) || get_in(r, ["generic", "vo2MaxValue"])

    %{vo2max: positive(value)}
  end

  defp endurance(r), do: %{endurance_score: int(r["overallScore"])}
  defp hill(r), do: %{hill_score: int(r["overallScore"])}
  defp training_status(r), do: %{training_status: status(r["trainingStatus"])}

  # -- ecriture ---------------------------------------------------------------

  @doc """
  Ecrit les journees accumulees, en ne reecrivant que les colonnes presentes.

  Publique parce que la synchronisation par l'API passe par le meme chemin
  d'ecriture : il n'y a qu'une facon d'enregistrer une journee.
  """
  @spec upsert(map()) :: non_neg_integer()
  def upsert(days) when map_size(days) == 0, do: 0

  def upsert(days) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      days
      |> Map.values()
      |> Enum.map(&Map.merge(&1, %{inserted_at: now, updated_at: now}))

    # Les colonnes reecrites sont celles reellement presentes dans le lot, et
    # non la liste complete du schema : ecraser avec `nil` une mesure absente
    # d'une famille effacerait ce qu'une autre famille avait apporte lors d'un
    # import precedent.
    replace =
      rows
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()
      |> Enum.reject(&(&1 in [:date, :inserted_at]))

    {count, _} =
      Repo.insert_all(DailyWellness, rows,
        on_conflict: {:replace, replace},
        conflict_target: [:date]
      )

    count
  end

  # -- primitives -------------------------------------------------------------

  defp drop_nils(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)

  defp num(value) when is_number(value), do: value * 1.0
  defp num(_value), do: nil

  defp int(value) when is_number(value), do: round(value)
  defp int(_value), do: nil

  # Garmin ecrit 0.0 pour « non mesure » sur plusieurs champs. Le distinguer
  # d'une vraie valeur nulle evite d'afficher une HRV a zero les nuits sans
  # port de la montre.
  defp positive(value) when is_number(value) and value > 0, do: value * 1.0
  defp positive(_value), do: nil

  defp status(value) when is_binary(value), do: String.downcase(value)
  defp status(_value), do: nil

  defp minutes_to_hours(nil), do: nil
  defp minutes_to_hours(minutes), do: Float.round(minutes / 60.0, 1)

  defp timestamp(raw) when is_binary(raw) do
    case NaiveDateTime.from_iso8601(raw) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC") |> DateTime.truncate(:second)
      _error -> nil
    end
  end

  defp timestamp(_raw), do: nil
end
