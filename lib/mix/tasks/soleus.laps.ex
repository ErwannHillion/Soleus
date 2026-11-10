defmodule Mix.Tasks.Soleus.Laps do
  @shortdoc "Relit les tours et les dynamiques de course des seances deja importees"

  @moduledoc """
  Rattrape les donnees que l'import initial ne lisait pas encore.

      mix soleus.laps

  Les tours et les dynamiques de course — oscillation verticale, temps de
  contact au sol, longueur de foulee, puissance — sont dans les fichiers FIT
  depuis le debut. L'import ne les extrayait pas.

  Plutot que de tout reimporter, cette tache relit chaque fichier a partir du
  chemin conserve en base, et reecrit les tours, les champs de seance et les
  **series**. Les efforts records ne sont pas recalcules : ils ne dependent
  que de la distance et du temps, qui n'ont pas change.

  Les seances dont le fichier a disparu sont signalees et ignorees : un
  chemin casse ne doit pas interrompre le rattrapage des autres.
  """

  use Mix.Task

  require Logger

  import Ecto.Query

  alias Soleus.Ingest.Fit
  alias Soleus.Repo
  alias Soleus.Training
  alias Soleus.Training.Activity

  @requirements ["app.start"]

  @extended ~w(
    avg_power max_power normalized_power vertical_oscillation_mm stance_time_ms
    step_length_mm vertical_ratio aerobic_effect anaerobic_effect total_strides
  )a

  @impl Mix.Task
  def run(_args) do
    Logger.configure(level: :warning)

    activities =
      Repo.all(from a in Activity, where: not is_nil(a.fit_path), order_by: [asc: a.started_at])

    total = length(activities)
    Mix.shell().info("#{total} seances a relire\n")

    tally =
      activities
      |> Enum.with_index(1)
      |> Enum.reduce(%{laps: 0, updated: 0, missing: 0, failed: 0}, fn {activity, index}, acc ->
        progress(index, total)
        reread(activity, acc)
      end)

    Mix.shell().info("""

    tours enregistres   #{tally.laps}
    seances completees  #{tally.updated}
    fichiers absents    #{tally.missing}
    echecs de lecture   #{tally.failed}\
    """)
  end

  defp reread(activity, tally) do
    if File.exists?(activity.fit_path) do
      decode(activity, tally)
    else
      Map.update!(tally, :missing, &(&1 + 1))
    end
  end

  defp decode(activity, tally) do
    case Fit.decode(activity.fit_path) do
      {:ok, decoded} ->
        laps = Training.insert_laps(activity, decoded[:laps] || [])
        Training.update_metrics(activity, Map.take(decoded, @extended))
        Training.replace_series(activity, decoded.series)

        tally
        |> Map.update!(:laps, &(&1 + laps))
        |> Map.update!(:updated, &(&1 + 1))

      {:error, _reason} ->
        Map.update!(tally, :failed, &(&1 + 1))
    end
  end

  defp progress(index, total) when rem(index, 10) == 0 or index == total do
    IO.write("\r  #{index} / #{total}")
    if index == total, do: IO.write("\n")
  end

  defp progress(_index, _total), do: :ok
end
