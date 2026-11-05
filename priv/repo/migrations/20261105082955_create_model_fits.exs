defmodule Soleus.Repo.Migrations.CreateModelFits do
  use Ecto.Migration

  def change do
    create table(:model_fits) do
      add :fitted_on, :date, null: false
      add :sport, :string, null: false
      add :window_days, :integer, null: false

      # Modele de vitesse critique a deux parametres :
      #   d(t) = cs * t + d_prime
      # cs est la vitesse soutenable en aerobie (m/s), d_prime la reserve
      # anaerobie finie (m). Ajuste sur la courbe des meilleurs efforts.
      add :cs_ms, :float
      add :d_prime_m, :float
      add :r2, :float
      add :sample_count, :integer

      add :vdot, :float

      # Temps predits par distance, en secondes : %{"5000" => 1369.0, ...}
      add :predictions, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:model_fits, [:fitted_on, :sport, :window_days])
    create index(:model_fits, [:sport, :fitted_on])
  end
end
