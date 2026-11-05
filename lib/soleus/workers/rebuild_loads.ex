defmodule Soleus.Workers.RebuildLoads do
  @moduledoc """
  Reconstruit la serie de charge quotidienne, puis reajuste les modeles.

  `unique` sur une fenetre d'une minute : c'est ce qui fait tenir un import de
  masse. Les centaines d'analyses qui se terminent en rafale demandent toutes
  le meme recalcul, et une seule execution les sert toutes.
  """

  use Oban.Worker, queue: :analytics, max_attempts: 3, unique: [period: 60]

  alias Soleus.Analytics
  alias Soleus.Workers.FitModels

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, _} = Analytics.rebuild_daily_loads()

    %{} |> FitModels.new() |> Oban.insert()
    :ok
  end
end
