defmodule Soleus.Repo.Migrations.CreateDailyLoads do
  use Ecto.Migration

  def change do
    create table(:daily_loads, primary_key: false) do
      add :date, :date, primary_key: true

      add :load, :float, null: false, default: 0.0
      add :distance_m, :float, null: false, default: 0.0
      add :moving_time_s, :integer, null: false, default: 0
      add :activity_count, :integer, null: false, default: 0

      # Modele de Banister : charge chronique (42 j), aigue (7 j), et leur
      # difference. Materialise parce que chaque jour depend du precedent :
      # recalculer la serie entiere a chaque affichage du tableau de bord
      # serait absurde.
      add :ctl, :float, null: false, default: 0.0
      add :atl, :float, null: false, default: 0.0
      add :tsb, :float, null: false, default: 0.0
      add :ramp_rate, :float

      timestamps(type: :utc_datetime)
    end
  end
end
