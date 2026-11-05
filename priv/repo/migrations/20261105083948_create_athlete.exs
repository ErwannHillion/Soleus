defmodule Soleus.Repo.Migrations.CreateAthlete do
  use Ecto.Migration

  def change do
    # Table a ligne unique : Soleus est une application personnelle, il n'y a
    # qu'un athlete. Une table plutot que du fichier de configuration parce
    # que ces valeurs se modifient depuis l'interface et changent avec le
    # temps, ce qu'un `config.exs` ne sait pas faire sans redemarrage.
    create table(:athlete, primary_key: false) do
      add :id, :integer, primary_key: true, default: 1

      add :name, :string
      add :sex, :string, null: false, default: "male"
      add :birth_date, :date
      add :weight_kg, :float

      # Laisses a nil par defaut : la FC max observee dans l'historique est une
      # meilleure estimation que 220 moins l'age, et le moteur sait la deduire.
      # Ces colonnes ne servent qu'a corriger a la main si besoin.
      add :hr_max, :integer
      add :hr_rest, :integer

      timestamps(type: :utc_datetime)
    end

    create constraint(:athlete, :athlete_is_singleton, check: "id = 1")

    execute "INSERT INTO athlete (id, sex, inserted_at, updated_at) VALUES (1, 'male', NOW(), NOW())",
            "DELETE FROM athlete WHERE id = 1"
  end
end
