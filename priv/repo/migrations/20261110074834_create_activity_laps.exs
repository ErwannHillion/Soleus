defmodule Soleus.Repo.Migrations.CreateActivityLaps do
  use Ecto.Migration

  def change do
    # Les tours tels que la montre les a enregistres, et non une decoupe
    # recalculee. Le fichier FIT porte un message `lap` par tour, avec son
    # **intensite** — echauffement, actif, recuperation, retour au calme —
    # qui est exactement ce qui distingue une serie de fractionne de la
    # trotte qui la suit. Aucune heuristique ne retrouverait cela aussi bien
    # que la montre, qui connaissait la seance programmee.
    create table(:activity_laps) do
      add :activity_id, references(:activities, on_delete: :delete_all), null: false

      add :index, :integer, null: false
      add :intensity, :string
      add :trigger, :string

      # Decalage depuis le depart de la seance, pour relier un tour aux
      # series et au trace sans avoir a recroiser les horodatages.
      add :start_offset_s, :integer
      add :duration_s, :float
      add :elapsed_s, :float
      add :distance_m, :float
      add :speed_ms, :float

      add :avg_hr, :integer
      add :max_hr, :integer
      add :avg_cadence, :float
      add :avg_power, :integer
      add :max_power, :integer
      add :normalized_power, :integer
      add :ascent_m, :float
      add :descent_m, :float

      # Dynamiques de course : oscillation verticale, temps de contact au sol,
      # longueur de foulee, ratio vertical.
      add :vertical_oscillation_mm, :float
      add :stance_time_ms, :float
      add :step_length_mm, :float
      add :vertical_ratio, :float

      timestamps(type: :utc_datetime)
    end

    create unique_index(:activity_laps, [:activity_id, :index])
    create index(:activity_laps, [:activity_id, :intensity])

    alter table(:activities) do
      add :avg_power, :integer
      add :max_power, :integer
      add :normalized_power, :integer
      add :vertical_oscillation_mm, :float
      add :stance_time_ms, :float
      add :step_length_mm, :float
      add :vertical_ratio, :float
      add :aerobic_effect, :float
      add :anaerobic_effect, :float
      add :total_strides, :integer
    end
  end
end
