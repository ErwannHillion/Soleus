defmodule Mix.Tasks.Soleus.Garmin do
  @shortdoc "Verifie la connexion a l'API personnelle Garmin"

  @moduledoc """
  Diagnostic et synchronisation manuelle de l'API personnelle Garmin.

      mix soleus.garmin check      # la cle donne-t-elle un jeton, et l'API repond-elle ?
      mix soleus.garmin sync       # synchronise les 7 derniers jours
      mix soleus.garmin sync 30    # ou une autre fenetre

  `check` ne se contente pas d'obtenir un jeton : il interroge un endpoint
  reel. Une cle peut etre acceptee a l'echange et refusee ensuite si le compte
  n'a pas les droits, et un diagnostic qui s'arreterait au jeton laisserait
  croire que tout va bien.
  """

  use Mix.Task

  require Logger

  alias Soleus.Config
  alias Soleus.Ingest.Garmin
  alias Soleus.Ingest.Garmin.Token
  alias Soleus.Workers.SyncGarmin

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    Logger.configure(level: :warning)

    case args do
      ["sync" | rest] -> sync(rest)
      _default -> check()
    end
  end

  defp check do
    if is_nil(Config.garmin_api_key()) do
      Mix.shell().error(Token.explain(:no_api_key))
      Mix.shell().info(setup_steps())
    else
      verify()
    end
  end

  defp verify do
    Mix.shell().info("1/2  echange de la cle contre un jeton...")

    case Token.fetch() do
      {:error, reason} ->
        Mix.shell().error("     #{Token.explain(reason)}")

      {:ok, token} ->
        Mix.shell().info("     jeton obtenu (#{String.length(token)} caracteres)")
        Mix.shell().info("\n2/2  appel d'un endpoint reel...")
        probe_data()
    end
  end

  defp probe_data do
    today = Date.utc_today()

    case Garmin.search_activities(Date.add(today, -30), today, limit: 5) do
      {:ok, []} ->
        Mix.shell().info("     API joignable, aucune activite sur 30 jours")

      {:ok, activities} ->
        Mix.shell().info("     #{length(activities)} activites sur les 30 derniers jours\n")

        Enum.each(activities, fn a ->
          Mix.shell().info(
            "       #{a["startTimeLocal"]}  #{a["activityName"]}  " <>
              "(id #{a["activityId"]})"
          )
        end)

        Mix.shell().info("\nTout est bon. Synchroniser : mix soleus.garmin sync")

      {:error, reason} ->
        Mix.shell().error("     #{inspect(reason)}")
    end
  end

  defp sync(rest) do
    days = rest |> List.first() |> parse_days()
    Mix.shell().info("synchronisation des #{days} derniers jours...")

    case SyncGarmin.perform(%Oban.Job{args: %{"window_days" => days}}) do
      :ok -> Mix.shell().info("termine. Enchainer avec : mix soleus.rebuild")
      {:cancel, reason} -> Mix.shell().error(Token.explain(reason))
      {:error, reason} -> Mix.shell().error(inspect(reason))
    end
  end

  defp parse_days(nil), do: 7

  defp parse_days(raw) do
    case Integer.parse(raw) do
      {days, ""} when days > 0 -> days
      _invalid -> Mix.raise("Fenetre invalide : #{raw}")
    end
  end

  defp setup_steps do
    """

    Marche a suivre :
      1. ouvrir https://connect.garmin.com/app/settings/personalApiToken
      2. creer une cle, en choisissant un an d'expiration
      3. la copier — elle n'est affichee qu'une seule fois
      4. l'ecrire dans .env :  GARMIN_API_KEY=...
      5. relancer  mix soleus.garmin check
    """
  end
end
