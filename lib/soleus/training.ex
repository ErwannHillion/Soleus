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
    with {:ok, decoded} <- Fit.decode(path) do
      case Repo.get_by(Activity, fit_digest: decoded.digest) do
        %Activity{} = existing ->
          {:ok, :already_imported, existing}

        nil ->
          persist(decoded, path, opts)
      end
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

  @doc "Les activites les plus recentes, sans leurs series."
  def list_activities(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    sport = Keyword.get(opts, :sport)

    Activity
    |> order_by(desc: :started_at)
    |> limit(^limit)
    |> maybe_sport(sport)
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
