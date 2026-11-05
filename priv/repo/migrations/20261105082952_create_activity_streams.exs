defmodule Soleus.Repo.Migrations.CreateActivityStreams do
  use Ecto.Migration

  def change do
    create table(:activity_streams) do
      add :activity_id, references(:activities, on_delete: :delete_all), null: false

      add :sample_count, :integer, null: false
      add :available, {:array, :string}, null: false, default: []

      # Toutes les series d'une activite dans un seul blob compresse plutot
      # qu'une ligne par point : une sortie d'une heure fait ~3600 points x 7
      # champs, soit une table a dizaines de millions de lignes pour quelques
      # annees d'historique. Ici c'est une lecture, un terme Erlang, et la
      # decompression est negligeable devant un aller-retour SQL par point.
      add :series, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:activity_streams, [:activity_id])
  end
end
