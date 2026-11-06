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
  alias Soleus.Training.{Activity, Athlete, BestEffort, Stream}

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

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # -- lecture ----------------------------------------------------------------

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
