defmodule Mix.Tasks.Soleus.Garmin do
  @shortdoc "Verifie la connexion a l'API personnelle Garmin"

  @moduledoc """
  Diagnostic et synchronisation manuelle de l'API personnelle Garmin.

      mix soleus.garmin check      # la cle donne-t-elle un jeton, et l'API repond-elle ?
      mix soleus.garmin sync       # seances des 7 derniers jours
      mix soleus.garmin sync 30    # ou une autre fenetre
      mix soleus.garmin sante      # donnees de sante des 30 derniers jours
      mix soleus.garmin probe      # forme brute des reponses de chaque endpoint

  ## `probe`

  Les formes exactes des reponses de l'API personnelle ne sont pas publiees.
  `probe` interroge chaque source de sante sur deux jours et affiche les cles
  reellement recues, ce qui permet de confirmer — ou de corriger — la
  traduction en une fois, avec une vraie cle.

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
  alias Soleus.Workers.{SyncGarmin, SyncWellness}

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    Logger.configure(level: :warning)

    case args do
      ["sync" | rest] -> sync(rest)
      ["sante" | rest] -> wellness(rest)
      ["probe" | _rest] -> probe()
      _default -> check()
    end
  end

  defp wellness(rest) do
    days = rest |> List.first() |> parse_days(30)
    Mix.shell().info("donnees de sante des #{days} derniers jours...")

    case SyncWellness.perform(%Oban.Job{args: %{"window_days" => days}}) do
      :ok -> Mix.shell().info("termine.")
      {:cancel, reason} -> Mix.shell().error(Token.explain(reason))
      {:error, reason} -> Mix.shell().error(inspect(reason))
    end
  end

  # Deux jours suffisent a reveler la forme d'une reponse, et evitent de
  # deverser un mois de mesures dans le terminal.
  defp probe do
    to = Date.utc_today()
    from = Date.add(to, -2)

    Enum.each(Garmin.wellness_sources(), fn {family, {kind, path} = source} ->
      Mix.shell().info("\n#{path}  (#{kind} → #{family})")

      case Garmin.raw_wellness(source, from, to) do
        {:ok, body} -> describe(body)
        {:error, reason} -> Mix.shell().error("  #{inspect(reason)}")
      end
    end)
  end

  defp describe(body) when is_list(body) do
    Mix.shell().info("  liste de #{length(body)} elements")
    body |> List.first() |> describe_record()
  end

  defp describe(%{} = body) do
    Mix.shell().info("  objet, cles : #{body |> Map.keys() |> Enum.sort() |> Enum.join(", ")}")

    Enum.each(body, fn
      {key, value} when is_list(value) and value != [] ->
        Mix.shell().info("  #{key} → liste de #{length(value)}")
        describe_record(List.first(value))

      _other ->
        :ok
    end)
  end

  defp describe(body), do: Mix.shell().info("  #{inspect(body, limit: 5)}")

  defp describe_record(%{} = record) do
    Mix.shell().info("    cles : #{record |> Map.keys() |> Enum.sort() |> Enum.join(", ")}")
  end

  defp describe_record(_other), do: :ok

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
        Mix.shell().info("Puis la sante : mix soleus.garmin sante")

      {:error, reason} ->
        Mix.shell().error("     #{inspect(reason)}")
    end
  end

  defp sync(rest) do
    days = rest |> List.first() |> parse_days(7)
    Mix.shell().info("synchronisation des #{days} derniers jours...")

    case SyncGarmin.perform(%Oban.Job{args: %{"window_days" => days}}) do
      :ok -> Mix.shell().info("termine. Enchainer avec : mix soleus.rebuild")
      {:cancel, reason} -> Mix.shell().error(Token.explain(reason))
      {:error, reason} -> Mix.shell().error(inspect(reason))
    end
  end

  defp parse_days(nil, default), do: default

  defp parse_days(raw, _default) do
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
