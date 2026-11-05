defmodule Soleus.Repo.Migrations.CreateDailyWellness do
  use Ecto.Migration

  def change do
    # Une ligne par jour, large plutot que normalisee. Le choix se justifie par
    # l'usage : ces mesures sont toujours lues ensemble, pour un meme jour, et
    # il y en a quelques centaines par an. Une table cle/valeur demanderait un
    # pivot a chaque affichage pour economiser un espace qui ne manque pas.
    create table(:daily_wellness, primary_key: false) do
      add :date, :date, primary_key: true

      # -- cardiovasculaire, avec les lignes de base personnelles de Garmin.
      # Les bornes comptent autant que la valeur : 57 battements au repos ne
      # veulent rien dire sans savoir que la normale de l'athlete est 50-69.
      add :resting_hr, :integer
      add :hr_baseline_low, :integer
      add :hr_baseline_high, :integer
      add :hr_status, :string

      add :hrv_overnight, :float
      add :hrv_baseline_low, :float
      add :hrv_baseline_high, :float
      add :hrv_status, :string
      add :hrv_weekly_avg, :float

      # -- respiratoire
      add :respiration_avg, :float
      add :respiration_low, :float
      add :respiration_high, :float
      add :spo2_avg, :float
      add :spo2_status, :string

      # -- thermique
      add :skin_temp_delta, :float
      add :skin_temp_status, :string

      # -- sommeil
      add :sleep_total_s, :integer
      add :sleep_deep_s, :integer
      add :sleep_light_s, :integer
      add :sleep_rem_s, :integer
      add :sleep_awake_s, :integer
      add :sleep_score, :integer
      add :sleep_quality_score, :integer
      add :sleep_recovery_score, :integer
      add :sleep_start, :utc_datetime
      add :sleep_end, :utc_datetime

      # -- energie et stress
      add :body_battery_high, :integer
      add :body_battery_low, :integer
      add :body_battery_charged, :integer
      add :body_battery_drained, :integer
      add :stress_avg, :integer
      add :stress_max, :integer
      add :stress_rest_s, :integer

      # -- activite quotidienne
      add :steps, :integer
      add :steps_goal, :integer
      add :floors, :float
      add :active_seconds, :integer
      add :calories_total, :integer
      add :calories_active, :integer
      add :intensity_moderate_min, :integer
      add :intensity_vigorous_min, :integer
      add :distance_m, :float

      # -- lecture de Garmin, conservee pour la confronter a la notre
      add :training_readiness, :integer
      add :recovery_time_h, :float
      add :garmin_acute_load, :float
      add :garmin_chronic_load, :float
      add :garmin_acwr, :float
      add :garmin_acwr_status, :string
      add :training_status, :string
      add :vo2max, :float
      add :endurance_score, :integer
      add :hill_score, :integer

      timestamps(type: :utc_datetime)
    end

    # Sert les graphes, qui lisent toujours une plage de dates ordonnee.
    create index(:daily_wellness, [:date])
  end
end
