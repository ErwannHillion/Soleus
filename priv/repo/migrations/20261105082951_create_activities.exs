defmodule Soleus.Repo.Migrations.CreateActivities do
  use Ecto.Migration

  def change do
    create table(:activities) do
      # Identite et provenance
      add :source, :string, null: false
      add :external_id, :string
      add :fit_digest, :string
      add :fit_path, :string

      # Descriptif
      add :sport, :string, null: false
      add :name, :string
      add :notes, :text
      add :started_at, :utc_datetime, null: false
      add :local_date, :date, null: false

      # Totaux
      add :distance_m, :float
      add :moving_time_s, :integer
      add :elapsed_time_s, :integer
      add :elevation_gain_m, :float
      add :calories, :integer

      # Cardio et cadence
      add :avg_hr, :integer
      add :max_hr, :integer
      add :avg_cadence, :float
      add :avg_speed_ms, :float
      add :max_speed_ms, :float

      # Metriques derivees par le moteur d'analyse
      add :trimp, :float
      add :load, :float
      add :decoupling, :float
      add :intensity_factor, :float

      add :analyzed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Idempotence de l'ingestion : un meme fichier FIT reimporte ne cree pas
    # de doublon, et une activite deja vue cote API non plus.
    create unique_index(:activities, [:fit_digest], where: "fit_digest IS NOT NULL")
    create unique_index(:activities, [:source, :external_id], where: "external_id IS NOT NULL")

    create index(:activities, [:started_at])
    create index(:activities, [:sport, :started_at])
    create index(:activities, [:local_date])
  end
end
