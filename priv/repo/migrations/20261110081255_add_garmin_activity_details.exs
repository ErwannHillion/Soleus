defmodule Soleus.Repo.Migrations.AddGarminActivityDetails do
  use Ecto.Migration

  def change do
    alter table(:activities) do
      # Vitesse corrigee de la pente : ce que l'allure aurait ete sur le plat.
      # La seule mesure qui rende deux sorties de profils differents
      # comparables.
      add :grade_adjusted_speed_ms, :float

      add :min_hr, :integer
      add :steps, :integer
      add :min_elevation_m, :float
      add :max_elevation_m, :float

      # Lecture de Garmin, conservee pour la confronter a la notre plutot que
      # pour la remplacer.
      add :garmin_load, :float
      add :vo2max, :float
      add :training_effect_label, :string

      add :intensity_moderate_min, :integer
      add :intensity_vigorous_min, :integer
      add :body_battery_delta, :integer
      add :bmr_calories, :integer
      add :water_ml, :integer

      # Temps par zone de puissance, meme forme que les zones cardiaques.
      add :power_zone_s, {:array, :integer}
    end
  end
end
