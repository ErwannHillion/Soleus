defmodule Soleus.Workers.SyncWellness do
  @moduledoc """
  Synchronise les donnees de sante quotidiennes depuis l'API personnelle.

  Sommeil, variabilite cardiaque, frequence au repos, reserve d'energie,
  stress, pas. Tout ce que la montre enregistre **hors seance**, et qui ne
  figure dans aucun fichier FIT.

  ## Une fenetre plus large que pour les seances

  Trente jours par defaut, contre sept pour les activites. Deux raisons :

    * ces mesures se consolident apres coup. Le score de sommeil d'une nuit
      peut etre revise le lendemain, la charge chronique l'est en continu ;
    * elles ne pesent rien. Une requete par famille couvre tout le mois, la
      ou chaque seance nouvelle demande un telechargement.

  ## Ce qui ne peut pas venir de l'API

  Les **lignes de base personnelles** — les fourchettes normales de
  variabilite cardiaque, de frequence au repos, de temperature cutanee —
  n'ont pas d'endpoint publie. Elles viennent de l'export RGPD et ne se
  rafraichiront pas toutes seules. La page Corps les utilise pour situer
  chaque mesure, donc elles vieilliront lentement sans que rien ne casse.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 3, unique: [period: 300]

  require Logger

  alias Soleus.Ingest.{Garmin, Wellness}
  alias Soleus.Ingest.Garmin.Token
  alias Soleus.Sync

  @default_window_days 30

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    days = Map.get(args, "window_days", @default_window_days)
    to = Date.utc_today()
    from = Date.add(to, -days)

    Sync.broadcast({:sync, :wellness_started, %{days: days}})

    case Token.fetch() do
      {:ok, _token} -> collect(from, to)
      {:error, reason} -> fail(reason)
    end
  end

  defp collect(from, to) do
    families = Garmin.wellness(from, to)

    days =
      Enum.reduce(families, %{}, fn {family, records}, acc ->
        Wellness.merge_records(acc, family, records)
      end)

    count = Wellness.upsert(days)
    received = families |> Enum.map(fn {_f, records} -> length(records) end) |> Enum.sum()

    Logger.info("Garmin sante : #{count} jours sur #{received} enregistrements recus")
    Sync.broadcast({:sync, :wellness_done, %{days: count, families: length(families)}})

    :ok
  end

  defp fail(reason) do
    Sync.broadcast({:sync, :failed, %{reason: reason}})

    if reason in [:no_api_key, :api_key_rejected] do
      {:cancel, reason}
    else
      {:error, reason}
    end
  end
end
