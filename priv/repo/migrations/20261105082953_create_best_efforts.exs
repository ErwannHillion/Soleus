defmodule Soleus.Repo.Migrations.CreateBestEfforts do
  use Ecto.Migration

  def change do
    create table(:best_efforts) do
      add :activity_id, references(:activities, on_delete: :delete_all), null: false

      # Deux familles d'efforts records, calculees sur la meme activite :
      #   :duration -> le plus rapide sur N secondes (courbe vitesse-duree)
      #   :distance -> le plus rapide sur N metres (records 1 km, 5 km...)
      add :kind, :string, null: false
      add :duration_s, :integer, null: false
      add :distance_m, :float, null: false
      add :speed_ms, :float, null: false
      add :avg_hr, :integer
      add :started_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:best_efforts, [:activity_id, :kind, :duration_s],
             where: "kind = 'duration'",
             name: :best_efforts_activity_duration_index
           )

    create unique_index(:best_efforts, [:activity_id, :kind, :distance_m],
             where: "kind = 'distance'",
             name: :best_efforts_activity_distance_index
           )

    # Sert la requete "mon record sur 5 km" : tri par vitesse a bucket fixe.
    create index(:best_efforts, [:kind, :duration_s, "speed_ms DESC"])
    create index(:best_efforts, [:kind, :distance_m, "speed_ms DESC"])
    create index(:best_efforts, [:started_at])
  end
end
