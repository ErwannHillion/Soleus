defmodule Soleus.Repo.Migrations.AddExponentToModelFits do
  use Ecto.Migration

  def change do
    alter table(:model_fits) do
      # L'exposant d'endurance reellement utilise pour les predictions longues,
      # et son origine : `personal` quand la courbe de l'athlete est assez
      # maximale pour l'ajuster, `literature` quand on retombe sur le 1.06 de
      # Riegel. Stocke plutot que recalcule a l'affichage, pour que l'interface
      # puisse dire d'ou vient un chiffre sans refaire l'ajustement.
      add :endurance_exponent, :float
      add :exponent_source, :string
    end
  end
end
