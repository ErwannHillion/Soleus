defmodule Mix.Tasks.Soleus.Wellness do
  @shortdoc "Importe les donnees de sante quotidiennes d'un export Garmin"

  @moduledoc """
  Lit le sommeil, la variabilite cardiaque, le stress, la reserve d'energie et
  le reste des mesures hors seance.

      mix soleus.wellness ~/Documents/data_garmin/DI_CONNECT

  Reexecutable sans risque : l'ecriture est un upsert par date, et seules les
  colonnes reellement presentes dans le lot sont reecrites.
  """

  use Mix.Task

  require Logger

  import Ecto.Query

  alias Soleus.Health.DailyWellness
  alias Soleus.Ingest.Wellness
  alias Soleus.Repo

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    Logger.configure(level: :warning)

    dir = List.first(args) || Mix.raise("Usage : mix soleus.wellness <racine DI_CONNECT>")

    case Wellness.import(dir) do
      {:ok, count} ->
        Mix.shell().info("#{count} jours importes\n")
        report()

      {:error, :no_wellness_files} ->
        Mix.raise("Aucun fichier de sante trouve sous #{dir}")
    end
  end

  # Le rapport compte les jours **renseignes** par mesure, et non les jours
  # presents : une montre peut ne pas etre portee la nuit, et une colonne a
  # moitie vide doit se voir ici plutot que d'etre decouverte a l'ecran.
  defp report do
    total = Repo.aggregate(DailyWellness, :count)

    [
      {"sommeil", :sleep_total_s},
      {"score de sommeil", :sleep_score},
      {"variabilite cardiaque", :hrv_overnight},
      {"FC au repos", :resting_hr},
      {"reserve d'energie", :body_battery_high},
      {"stress", :stress_avg},
      {"pas", :steps},
      {"VO2max", :vo2max},
      {"etat de forme Garmin", :training_readiness},
      {"charge aigue Garmin", :garmin_acute_load},
      {"score d'endurance", :endurance_score},
      {"temperature cutanee", :skin_temp_delta}
    ]
    |> Enum.each(fn {label, field} ->
      filled =
        Repo.one(from d in DailyWellness, where: not is_nil(field(d, ^field)), select: count())

      Mix.shell().info(
        "  #{String.pad_trailing(label, 24)} #{String.pad_leading(to_string(filled), 4)} / #{total}"
      )
    end)

    range =
      Repo.one(from d in DailyWellness, select: {min(d.date), max(d.date)})

    case range do
      {from, to} when not is_nil(from) -> Mix.shell().info("\nperiode : #{from} -> #{to}")
      _empty -> :ok
    end
  end
end
