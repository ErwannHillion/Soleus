defmodule Soleus.Workers.SyncGarmin do
  @moduledoc """
  Synchronisation incrementale depuis l'API personnelle Garmin.

  Interroge les activites d'une fenetre recente, telecharge le fichier
  d'origine de celles qu'on n'a pas, et les passe au pipeline d'import.

  ## Pourquoi une fenetre et pas un curseur

  L'API ne propose pas de webhook ni de « depuis tel instant » : seulement une
  recherche par plage de dates. On repasse donc sur une fenetre glissante, par
  defaut sept jours.

  Repasser sur des activites deja connues ne coute presque rien — la recherche
  rend un resume, et on ne telecharge que ce qui manque. En revanche une
  fenetre trop courte perdrait une seance synchronisee en retard parce que la
  montre est restee quelques jours sans se connecter, et ce trou ne serait
  jamais rattrape.

  ## Ce qui n'est pas gere, et ne peut pas l'etre

  La cle personnelle expire au bout d'un an au plus, et Garmin n'emet pas de
  jeton de rafraichissement. Quand elle expire, ce job echoue avec
  `:api_key_rejected` : c'est un `:discard`, pas une erreur a reessayer. Seul
  l'athlete peut en regenerer une a la main.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 3, unique: [period: 300]

  require Logger

  alias Soleus.Config
  alias Soleus.Ingest.Garmin
  alias Soleus.Ingest.Garmin.Token
  alias Soleus.Sync
  alias Soleus.Training
  alias Soleus.Workers.RebuildLoads

  @default_window_days 7

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    days = Map.get(args, "window_days", @default_window_days)
    to = Date.utc_today()
    from = Date.add(to, -days)

    Sync.broadcast({:sync, :started, %{days: days}})

    case Garmin.search_activities(from, to) do
      {:ok, activities} -> import_all(activities)
      {:error, reason} -> fail(reason)
    end
  end

  defp import_all(activities) do
    total = length(activities)
    Sync.broadcast({:sync, :found, %{total: total}})

    imported =
      activities
      |> Enum.with_index(1)
      |> Enum.reduce(0, fn {activity, index}, done ->
        Sync.broadcast({:sync, :progress, %{index: index, total: total}})
        import_one(activity, done)
      end)

    if imported > 0 do
      Logger.info("Garmin : #{imported} nouvelle(s) seance(s)")
      %{} |> RebuildLoads.new() |> Oban.insert()
    end

    Sync.broadcast({:sync, :done, %{imported: imported, seen: total}})
    :ok
  end

  defp fail(:api_key_rejected) do
    Logger.error(Token.explain(:api_key_rejected))
    Sync.broadcast({:sync, :failed, %{reason: :api_key_rejected}})
    {:discard, :api_key_rejected}
  end

  # Pas une panne : la synchronisation est optionnelle, et l'import de
  # fichiers FIT fonctionne sans cle.
  defp fail(:no_api_key) do
    Sync.broadcast({:sync, :failed, %{reason: :no_api_key}})
    {:discard, :no_api_key}
  end

  defp fail(reason) do
    Sync.broadcast({:sync, :failed, %{reason: reason}})
    {:error, reason}
  end

  defp import_one(%{"activityId" => id}, imported) do
    dir = Path.join(Config.fit_import_dir(), "garmin")

    with {:ok, path} <- Garmin.download_activity(id, dir),
         {:ok, :imported, _activity} <- Training.import_fit(path) do
      imported + 1
    else
      {:ok, :already_imported, _activity} ->
        imported

      {:error, reason} ->
        Logger.warning("Garmin : activite #{id} non importee — #{inspect(reason)}")
        imported
    end
  end

  defp import_one(_activity, imported), do: imported
end
