defmodule Soleus.Repo.Migrations.AddHeartRateZones do
  use Ecto.Migration

  def change do
    alter table(:activities) do
      # Temps passe dans chaque zone, en secondes, de la zone 0 (sous la zone
      # 1) a la zone 5. Un tableau plutot que six colonnes : les zones se
      # lisent toujours ensemble, comme une repartition, et jamais une par
      # une. Six colonnes imposeraient de les nommer, de les migrer et de les
      # selectionner a chaque requete pour un gain nul.
      add :hr_zone_s, {:array, :integer}
    end

    alter table(:athlete) do
      # Les planchers des zones 1 a 5, tels que la montre les applique. Sans
      # eux, un temps par zone n'est qu'une suite de nombres : c'est le
      # plancher qui dit ce que « zone 3 » veut dire en battements.
      add :hr_zone_floors, {:array, :integer}
    end
  end
end
