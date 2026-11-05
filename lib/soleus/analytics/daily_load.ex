defmodule Soleus.Analytics.DailyLoad do
  @moduledoc """
  Une journee de charge d'entrainement, avec l'etat du modele de Banister.

  `ctl`, `atl` et `tsb` sont materialises parce que chaque jour depend du
  precedent : ce sont des moyennes exponentielles, pas des agregats. Les
  recalculer a chaque affichage obligerait a relire tout l'historique.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:date, :date, autogenerate: false}

  schema "daily_loads" do
    field :load, :float, default: 0.0
    field :distance_m, :float, default: 0.0
    field :moving_time_s, :integer, default: 0
    field :activity_count, :integer, default: 0

    field :ctl, :float, default: 0.0
    field :atl, :float, default: 0.0
    field :tsb, :float, default: 0.0
    field :ramp_rate, :float

    timestamps(type: :utc_datetime)
  end

  def changeset(daily_load, attrs) do
    daily_load
    |> cast(attrs, [
      :date,
      :load,
      :distance_m,
      :moving_time_s,
      :activity_count,
      :ctl,
      :atl,
      :tsb,
      :ramp_rate
    ])
    |> validate_required([:date])
  end
end
