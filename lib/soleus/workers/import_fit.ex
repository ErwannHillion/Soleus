defmodule Soleus.Workers.ImportFit do
  @moduledoc """
  Importe un fichier FIT, puis enchaine sur son analyse.

  `unique` sur le chemin : un dossier surveille peut signaler le meme fichier
  plusieurs fois, et le decodage est assez couteux pour qu'il vaille la peine
  de ne pas le refaire. L'idempotence est deja garantie en base par
  l'empreinte du fichier, celle-ci evite juste le travail inutile.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 3, unique: [keys: [:path], period: 300]

  alias Soleus.Training
  alias Soleus.Workers.AnalyzeActivity

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"path" => path}}) do
    case Training.import_fit(path) do
      {:ok, :imported, activity} ->
        %{activity_id: activity.id}
        |> AnalyzeActivity.new()
        |> Oban.insert()

        :ok

      {:ok, :already_imported, _activity} ->
        :ok

      {:error, reason} ->
        # `:discard` et non une erreur : un fichier illisible le restera aux
        # deux tentatives suivantes. Le reessayer ne fait que retarder le
        # reste du lot.
        {:discard, reason}
    end
  end
end
