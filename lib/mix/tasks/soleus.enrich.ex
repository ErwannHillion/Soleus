defmodule Mix.Tasks.Soleus.Enrich do
  @shortdoc "Complete les seances importees depuis le resume JSON de Garmin"

  @moduledoc """
  Pose sur les seances deja importees les informations que le fichier FIT ne
  porte pas.

      mix soleus.enrich chemin/vers/..._summarizedActivities.json

  Le nom affiche dans Garmin Connect ("Course a pied le midi") n'existe que
  dans ce JSON : le fichier FIT, lui, ne contient que des mesures. Sans cette
  etape, la liste des seances n'affiche que des tirets.

  ## L'appariement

  Les identifiants ne sont d'aucun secours : le nom de fichier FIT porte un
  numero de televersement, pas l'`activityId` du resume. L'appariement se fait
  donc sur l'instant de depart, avec une tolerance de deux minutes.

  C'est suffisamment discriminant en pratique — deux seances ne commencent pas
  a la meme minute — et robuste a l'ecart de quelques secondes entre
  l'horodatage du fichier et celui enregistre par Connect.
  """

  use Mix.Task

  require Logger

  import Ecto.Query

  alias Soleus.Repo
  alias Soleus.Training.Activity

  @requirements ["app.start"]

  # Deux minutes : assez large pour absorber l'ecart entre l'horodatage du
  # fichier et celui du serveur, assez etroit pour ne jamais confondre deux
  # seances distinctes.
  @tolerance_s 120

  @impl Mix.Task
  def run(args) do
    Logger.configure(level: :warning)

    path = List.first(args) || Mix.raise("Usage : mix soleus.enrich <summarizedActivities.json>")

    summaries = load(path)
    Mix.shell().info("#{length(summaries)} activites dans le resume")

    activities = Repo.all(from a in Activity, select: %{id: a.id, started_at: a.started_at})
    updated = Enum.reduce(activities, 0, &apply_summary(&1, summaries, &2))

    Mix.shell().info("#{updated} seances nommees sur #{length(activities)}")
  end

  defp load(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> case do
      # Garmin encapsule la liste dans un objet a une cle, dont le nom varie
      # selon la version de l'export.
      [%{} = wrapper] -> wrapper |> Map.values() |> List.flatten()
      list when is_list(list) -> list
      %{} = map -> map |> Map.values() |> List.flatten()
    end
    |> Enum.filter(&(is_map(&1) and Map.has_key?(&1, "startTimeGmt")))
  end

  defp apply_summary(activity, summaries, count) do
    case Enum.find(summaries, &matches?(&1, activity.started_at)) do
      nil ->
        count

      summary ->
        attrs = %{name: summary["name"], notes: summary["locationName"]}

        from(a in Activity, where: a.id == ^activity.id)
        |> Repo.update_all(set: Enum.reject(attrs, fn {_k, v} -> is_nil(v) end))

        count + 1
    end
  end

  defp matches?(summary, started_at) do
    case to_datetime(summary["startTimeGmt"]) do
      nil -> false
      at -> abs(DateTime.diff(at, started_at)) <= @tolerance_s
    end
  end

  # Garmin exporte l'instant en millisecondes depuis l'epoque, parfois en
  # chaine ISO selon le champ et la version.
  #
  # Et en **flottant** : `startTimeGmt` sort a `1793788764000.0`. Un decodeur
  # JSON le rend donc en float, que `DateTime.from_unix!/2` refuse. C'est ce
  # qui faisait echouer silencieusement les 134 appariements.
  defp to_datetime(value) when is_float(value), do: to_datetime(round(value))

  defp to_datetime(value) when is_integer(value), do: DateTime.from_unix!(value, :millisecond)

  defp to_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _error -> nil
    end
  end

  defp to_datetime(_value), do: nil
end
