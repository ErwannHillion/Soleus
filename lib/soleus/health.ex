defmodule Soleus.Health do
  @moduledoc """
  Les mesures physiologiques hors seance, et leur lecture.

  Ce contexte repond a une question differente de `Soleus.Analytics` : non pas
  « quelle performance ? » mais « dans quel etat ? ». Les deux se rejoignent a
  l'usage — une charge productive sur une semaine de mauvais sommeil n'est pas
  la meme chose que la meme charge reposee — mais leurs donnees et leurs
  modeles sont distincts, d'ou la separation.
  """

  import Ecto.Query

  alias Soleus.Health.DailyWellness
  alias Soleus.Repo

  @doc "La journee la plus recente qui porte au moins une mesure."
  @spec latest() :: DailyWellness.t() | nil
  def latest do
    Repo.one(from d in DailyWellness, order_by: [desc: d.date], limit: 1)
  end

  @doc """
  Etat courant, reconstitue a partir des derniers jours mesures.

  Pas simplement la derniere ligne : les mesures n'arrivent pas toutes le meme
  jour. La journee en cours a deja sa frequence au repos et son sommeil, mais
  pas encore sa charge d'entrainement, et la VO2max n'est reestimee qu'apres
  certaines seances. Lire la seule derniere ligne afficherait donc des tirets
  sur des mesures parfaitement connues de la veille.

  Chaque champ prend donc sa valeur connue la plus recente dans la fenetre, et
  `as_of` retient la date de la ligne la plus recente pour que l'interface
  puisse dire de quand date l'ensemble.
  """
  @spec snapshot(pos_integer()) :: {map(), Date.t()} | nil
  def snapshot(window_days \\ 14) do
    since = Date.add(Date.utc_today(), -window_days)

    Repo.all(
      from d in DailyWellness,
        where: d.date >= ^since,
        order_by: [desc: d.date]
    )
    |> case do
      [] ->
        nil

      [most_recent | _] = days ->
        {Enum.reduce(days, %{}, &carry_forward/2), most_recent.date}
    end
  end

  # Les jours sont parcourus du plus recent au plus ancien, donc le premier
  # non nul rencontre pour un champ est bien sa valeur la plus recente.
  defp carry_forward(day, acc) do
    Enum.reduce(DailyWellness.fields(), acc, fn field, taken ->
      case {Map.get(taken, field), Map.get(day, field)} do
        {nil, value} when not is_nil(value) -> Map.put(taken, field, value)
        _already_set -> taken
      end
    end)
  end

  @doc "Les journees d'une plage, ordonnees."
  @spec range(Date.t(), Date.t()) :: [DailyWellness.t()]
  def range(from, to) do
    Repo.all(
      from d in DailyWellness, where: d.date >= ^from and d.date <= ^to, order_by: [asc: d.date]
    )
  end

  @doc "Bornes de l'historique disponible, ou `nil` si la base est vide."
  @spec bounds() :: {Date.t(), Date.t()} | nil
  def bounds do
    case Repo.one(from d in DailyWellness, select: {min(d.date), max(d.date)}) do
      {from, to} when not is_nil(from) -> {from, to}
      _empty -> nil
    end
  end

  @doc """
  Moyennes d'une plage, pour comparer deux periodes.

  `nil` est ignore plutot que compte comme zero : une nuit sans la montre ne
  doit pas faire chuter la moyenne de sommeil du mois.
  """
  @spec averages(Date.t(), Date.t()) :: map()
  def averages(from, to) do
    Repo.one(
      from d in DailyWellness,
        where: d.date >= ^from and d.date <= ^to,
        select: %{
          days: count(d.date),
          resting_hr: avg(d.resting_hr),
          hrv_overnight: avg(d.hrv_overnight),
          sleep_total_s: avg(d.sleep_total_s),
          sleep_score: avg(d.sleep_score),
          stress_avg: avg(d.stress_avg),
          body_battery_high: avg(d.body_battery_high),
          body_battery_low: avg(d.body_battery_low),
          steps: avg(d.steps),
          training_readiness: avg(d.training_readiness),
          respiration_avg: avg(d.respiration_avg)
        }
    )
    |> decimals_to_floats()
  end

  @doc """
  Serie d'une mesure sur une plage, pour les graphes.

  Rend `[{date, valeur}]` sans les jours non mesures : un graphe doit montrer
  un trou la ou il y en a un, pas une chute a zero.
  """
  @spec series(atom(), Date.t(), Date.t()) :: [{Date.t(), number()}]
  def series(field, from, to) when is_atom(field) do
    Repo.all(
      from d in DailyWellness,
        where: d.date >= ^from and d.date <= ^to and not is_nil(field(d, ^field)),
        order_by: [asc: d.date],
        select: {d.date, field(d, ^field)}
    )
  end

  @doc """
  Derniere valeur connue d'une mesure, avec sa date.

  Indispensable pour les mesures intrinsequement creuses : Garmin ne reestime
  la VO2max qu'apres certaines seances, donc la lire sur le seul jour courant
  donnerait presque toujours `nil`. L'interface doit alors afficher la valeur
  **et** sa date, pour qu'on sache qu'elle date de la semaine derniere.
  """
  @spec last_known(atom()) :: {Date.t(), number()} | nil
  def last_known(field) when is_atom(field) do
    Repo.one(
      from d in DailyWellness,
        where: not is_nil(field(d, ^field)),
        order_by: [desc: d.date],
        limit: 1,
        select: {d.date, field(d, ^field)}
    )
  end

  @doc """
  Etat des grands systemes, tel qu'affiche par le schema corporel.

  Chaque systeme porte un statut derive des lignes de base personnelles de
  l'athlete, jamais d'un seuil universel. Voir `Soleus.Health.DailyWellness`.
  """
  @spec systems(map() | nil) :: [map()]
  def systems(nil), do: []

  def systems(day) do
    day = Map.new(DailyWellness.fields(), &{&1, Map.get(day, &1)})

    [
      %{
        key: :sleep,
        label: "Sommeil",
        region: "tete",
        status: sleep_status(day.sleep_score),
        value: score_text(day.sleep_score),
        detail: duration_text(day.sleep_total_s)
      },
      %{
        key: :stress,
        label: "Stress",
        region: "tete",
        status: stress_status(day.stress_avg),
        value: score_text(day.stress_avg),
        detail: "max #{score_text(day.stress_max)}"
      },
      %{
        key: :heart,
        label: "Frequence au repos",
        region: "coeur",
        status: DailyWellness.situate(day.resting_hr, day.hr_baseline_low, day.hr_baseline_high),
        value: unit_text(day.resting_hr, "bpm"),
        detail: baseline_text(day.hr_baseline_low, day.hr_baseline_high, "bpm")
      },
      %{
        key: :hrv,
        label: "Variabilite cardiaque",
        region: "coeur",
        status:
          DailyWellness.situate(day.hrv_overnight, day.hrv_baseline_low, day.hrv_baseline_high),
        value: unit_text(day.hrv_overnight, "ms"),
        detail: baseline_text(day.hrv_baseline_low, day.hrv_baseline_high, "ms")
      },
      %{
        key: :respiration,
        label: "Respiration",
        region: "poumons",
        status: :in_range,
        value: unit_text(day.respiration_avg, "/min"),
        detail: range_text(day.respiration_low, day.respiration_high)
      },
      %{
        key: :energy,
        label: "Reserve d'energie",
        region: "tronc",
        status: battery_status(day.body_battery_high),
        value: score_text(day.body_battery_high),
        detail: "creux a #{score_text(day.body_battery_low)}"
      },
      %{
        key: :readiness,
        label: "Etat de forme",
        region: "tronc",
        status: readiness_status(day.training_readiness),
        value: score_text(day.training_readiness),
        detail: recovery_text(day.recovery_time_h)
      },
      %{
        key: :load,
        label: "Charge aigue",
        region: "jambes",
        status: acwr_status(day.garmin_acwr),
        value: score_text(day.garmin_acute_load),
        detail: acwr_text(day.garmin_acwr)
      },
      %{
        key: :vo2max,
        label: "VO2max estimee",
        region: "coeur",
        status: if(is_number(day.vo2max), do: :in_range, else: :unknown),
        value: unit_text(day.vo2max, "ml/kg/min"),
        detail: "estimation Garmin"
      },
      %{
        key: :skin,
        label: "Temperature cutanee",
        region: "peau",
        status: status_atom(day.skin_temp_status),
        value: delta_text(day.skin_temp_delta),
        detail: "ecart a la normale"
      }
    ]
  end

  # -- interpretations --------------------------------------------------------
  #
  # Les seuils ci-dessous sont ceux des echelles publiees par Garmin, qui sont
  # deja normalisees de 0 a 100. Ils ne s'appliquent qu'a ces scores-la : les
  # mesures brutes (FC, HRV, temperature) passent par les lignes de base
  # personnelles, et jamais par un seuil fixe.

  defp sleep_status(score) when is_number(score) and score >= 80, do: :in_range
  defp sleep_status(score) when is_number(score) and score >= 60, do: :watch
  defp sleep_status(score) when is_number(score), do: :low
  defp sleep_status(_score), do: :unknown

  defp stress_status(avg) when is_number(avg) and avg <= 25, do: :in_range
  defp stress_status(avg) when is_number(avg) and avg <= 50, do: :watch
  defp stress_status(avg) when is_number(avg), do: :high
  defp stress_status(_avg), do: :unknown

  defp battery_status(high) when is_number(high) and high >= 70, do: :in_range
  defp battery_status(high) when is_number(high) and high >= 40, do: :watch
  defp battery_status(high) when is_number(high), do: :low
  defp battery_status(_high), do: :unknown

  defp readiness_status(score) when is_number(score) and score >= 70, do: :in_range
  defp readiness_status(score) when is_number(score) and score >= 40, do: :watch
  defp readiness_status(score) when is_number(score), do: :low
  defp readiness_status(_score), do: :unknown

  # Le rapport charge aigue sur charge chronique. La fenetre 0,8-1,3 est celle
  # ou la litterature situe le meilleur compromis entre progression et risque
  # de blessure ; au dela de 1,5 le risque augmente nettement.
  defp acwr_status(ratio) when is_number(ratio) and ratio >= 0.8 and ratio <= 1.3, do: :in_range
  defp acwr_status(ratio) when is_number(ratio) and ratio < 0.8, do: :low
  defp acwr_status(ratio) when is_number(ratio) and ratio <= 1.5, do: :watch
  defp acwr_status(ratio) when is_number(ratio), do: :high
  defp acwr_status(_ratio), do: :unknown

  defp status_atom("in_range"), do: :in_range
  defp status_atom("above_range"), do: :high
  defp status_atom("below_range"), do: :low
  defp status_atom(_other), do: :unknown

  # -- mise en forme ----------------------------------------------------------

  defp score_text(nil), do: "—"
  defp score_text(value) when is_float(value), do: value |> round() |> Integer.to_string()
  defp score_text(value), do: to_string(value)

  defp unit_text(nil, _unit), do: "—"
  defp unit_text(value, unit) when is_float(value), do: "#{Float.round(value, 1)} #{unit}"
  defp unit_text(value, unit), do: "#{value} #{unit}"

  defp baseline_text(low, high, unit) when is_number(low) and is_number(high),
    do: "normale #{round(low)}–#{round(high)} #{unit}"

  defp baseline_text(_low, _high, _unit), do: "normale inconnue"

  defp range_text(low, high) when is_number(low) and is_number(high),
    do: "#{round(low)}–#{round(high)} /min"

  defp range_text(_low, _high), do: "—"

  defp duration_text(nil), do: "—"

  defp duration_text(seconds) do
    hours = div(seconds, 3600)
    minutes = seconds |> rem(3600) |> div(60)
    "#{hours} h #{String.pad_leading(to_string(minutes), 2, "0")}"
  end

  defp recovery_text(nil), do: "recuperation inconnue"
  defp recovery_text(hours) when hours <= 0, do: "recupere"
  defp recovery_text(hours), do: "#{Float.round(hours, 1)} h de recuperation"

  defp delta_text(nil), do: "—"
  # Garmin ecrit un ecart nul quand la temperature est sur sa normale. Le
  # rendre en clair evite d'afficher « +0.0 °C », qui se lit comme une mesure
  # ratee alors que c'est le bon resultat.
  defp delta_text(delta) when is_number(delta) and delta == 0, do: "normale"
  defp delta_text(delta) when delta > 0, do: "+#{Float.round(delta, 1)} °C"
  defp delta_text(delta), do: "#{Float.round(delta, 1)} °C"

  defp acwr_text(nil), do: "rapport inconnu"
  defp acwr_text(ratio), do: "rapport aigu/chronique #{Float.round(ratio, 2)}"

  defp decimals_to_floats(nil), do: %{}

  defp decimals_to_floats(map) do
    Map.new(map, fn
      {k, %Decimal{} = d} -> {k, Decimal.to_float(d)}
      {k, v} -> {k, v}
    end)
  end
end
