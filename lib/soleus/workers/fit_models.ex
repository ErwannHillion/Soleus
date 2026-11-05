defmodule Soleus.Workers.FitModels do
  @moduledoc """
  Reajuste les modeles physiologiques du jour.

  Tourne aussi en cron quotidien, et pas seulement apres un import : la
  fenetre glissante de 90 jours avance chaque nuit, donc la vitesse critique
  change meme un jour sans seance — un effort record sort de la fenetre, et
  l'ajustement doit en tenir compte.
  """

  use Oban.Worker, queue: :analytics, max_attempts: 3, unique: [period: 60]

  alias Soleus.Analytics

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    sport = Map.get(args, "sport", "run")
    on = args |> Map.get("on") |> parse_date()

    case Analytics.fit_models(sport, on) do
      {:ok, _fit} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_date(nil), do: Date.utc_today()

  defp parse_date(raw) do
    case Date.from_iso8601(raw) do
      {:ok, date} -> date
      _ -> Date.utc_today()
    end
  end
end
