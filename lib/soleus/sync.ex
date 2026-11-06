defmodule Soleus.Sync do
  @moduledoc """
  Declenchement et suivi de la synchronisation Garmin.

  ## Pourquoi un declenchement manuel et au demarrage

  La tache planifiee de minuit ne sert a rien sur un poste qu'on eteint : le
  cron d'Oban ne se rattrape pas, il ne declenche que si l'application tourne
  a l'instant dit. Sur un portable allume quelques heures par jour, elle ne
  partira presque jamais.

  Deux chemins s'ajoutent donc :

    * **au demarrage**, une synchronisation est programmee quelques secondes
      apres le boot. C'est le comportement attendu quand on ouvre
      l'application de temps en temps : elle rattrape ce qui manque ;
    * **a la demande**, par un bouton de l'interface.

  Les trois chemins passent par le meme job, qui est `unique` sur cinq
  minutes : ouvrir l'application juste avant minuit et cliquer sur le bouton
  ne declenche qu'une seule execution.

  ## Le suivi

  L'avancement passe par PubSub plutot que par la valeur de retour du job :
  le travail doit survivre a la fermeture de l'onglet, et plusieurs vues
  peuvent l'observer en meme temps.
  """

  import Ecto.Query

  require Logger

  alias Soleus.Config
  alias Soleus.Repo
  alias Soleus.Workers.SyncGarmin

  @topic "garmin:sync"

  # Le temps que l'application finisse de demarrer avant de solliciter le
  # reseau. Sans ce delai, la synchronisation entre en concurrence avec la
  # compilation des assets et la premiere requete HTTP au demarrage en mode
  # developpement.
  @boot_delay_s 20

  @doc "S'abonner aux evenements de synchronisation."
  def subscribe, do: Phoenix.PubSub.subscribe(Soleus.PubSub, @topic)

  @doc false
  def broadcast(message), do: Phoenix.PubSub.broadcast(Soleus.PubSub, @topic, message)

  @doc """
  Programme une synchronisation.

  Rend `{:error, :no_api_key}` sans rien programmer quand aucune cle n'est
  configuree : mieux vaut le dire tout de suite a l'interface que de faire
  echouer un job dont personne ne lira le resultat.
  """
  @spec trigger(keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def trigger(opts \\ []) do
    if is_nil(Config.garmin_api_key()) do
      {:error, :no_api_key}
    else
      %{"window_days" => Keyword.get(opts, :window_days, 7)}
      |> SyncGarmin.new(schedule_in: Keyword.get(opts, :delay_s, 0))
      |> Oban.insert()
    end
  end

  @doc """
  Programme la synchronisation de rattrapage du demarrage.

  Appelee depuis l'arbre de supervision. Silencieuse en l'absence de cle, et
  volontairement tolerante : une base pas encore migree ou un Oban pas encore
  pret ne doivent pas empecher l'application de demarrer.
  """
  @spec schedule_boot_catch_up() :: :ok
  def schedule_boot_catch_up do
    case trigger(delay_s: @boot_delay_s) do
      {:ok, _job} -> Logger.info("Garmin : rattrapage programme dans #{@boot_delay_s} s")
      {:error, :no_api_key} -> :ok
      {:error, reason} -> Logger.warning("Garmin : rattrapage impossible — #{inspect(reason)}")
    end

    :ok
  rescue
    error ->
      Logger.warning("Garmin : rattrapage impossible — #{inspect(error)}")
      :ok
  end

  @doc """
  Etat de la derniere synchronisation, lu dans l'historique d'Oban.

  Pas de table dediee : Oban conserve deja l'etat, l'horodatage et le nombre
  de tentatives de chaque job. En ajouter une seconde creerait deux sources de
  verite a garder d'accord.

  Le Pruner efface les jobs apres une semaine, donc une absence de resultat
  signifie « rien depuis au moins sept jours », pas « jamais ».
  """
  @spec last_sync() :: map() | nil
  def last_sync do
    Repo.one(
      from j in "oban_jobs",
        where: j.worker == "Soleus.Workers.SyncGarmin",
        where:
          j.state in [
            "completed",
            "cancelled",
            "discarded",
            "retryable",
            "executing",
            "available"
          ],
        order_by: [desc: j.id],
        limit: 1,
        select: %{
          state: j.state,
          at: j.attempted_at,
          completed_at: j.completed_at,
          errors: j.errors
        }
    )
  end

  @doc "Y a-t-il une synchronisation en cours ou en attente ?"
  @spec running?() :: boolean()
  def running? do
    Repo.exists?(
      from j in "oban_jobs",
        where: j.worker == "Soleus.Workers.SyncGarmin",
        where: j.state in ["available", "scheduled", "executing", "retryable"]
    )
  end
end
