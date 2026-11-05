defmodule Soleus.Workers.AnalyzeActivity do
  @moduledoc """
  Calcule les metriques d'une seance, puis declenche le recalcul de la charge.

  La charge quotidienne n'est pas recalculee ici mais dans un job distinct et
  unique : un import de 500 fichiers produit 500 analyses, et chacune
  declencherait une reconstruction complete de la serie de Banister. Le job
  dedie est `unique`, donc les 500 demandes se fondent en une.
  """

  use Oban.Worker, queue: :analytics, max_attempts: 3

  alias Soleus.{Analytics, Training}
  alias Soleus.Workers.RebuildLoads

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"activity_id" => id}}) do
    activity = Training.get_activity!(id)
    athlete = Training.athlete()
    cs_fit = Analytics.current_fit(activity.sport)

    cs =
      case cs_fit do
        %{cs_ms: cs, d_prime_m: d} when is_number(cs) and is_number(d) ->
          %{cs_ms: cs, d_prime_m: d, r2: 1.0, sample_count: 0}

        _ ->
          nil
      end

    with {:ok, _activity} <- Analytics.analyze_activity(activity, athlete, cs) do
      %{} |> RebuildLoads.new() |> Oban.insert()
      :ok
    end
  end
end
