defmodule Soleus.Training.BestEffort do
  @moduledoc """
  Le meilleur effort d'une activite sur une duree ou une distance donnee.

  Deux familles, parce qu'elles repondent a deux questions differentes :

    * `"duration"` alimente la courbe vitesse-duree, qui est l'entree du
      modele de vitesse critique ;
    * `"distance"` donne les records personnels lisibles ("mon meilleur
      5 km"), qui sont ce qu'un coureur regarde en premier.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(duration distance)

  schema "best_efforts" do
    belongs_to :activity, Soleus.Training.Activity

    field :kind, :string
    field :duration_s, :integer
    field :distance_m, :float
    field :speed_ms, :float
    field :avg_hr, :integer
    field :started_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(effort, attrs) do
    effort
    |> cast(attrs, [:activity_id, :kind, :duration_s, :distance_m, :speed_ms, :avg_hr, :started_at])
    |> validate_required([:activity_id, :kind, :duration_s, :distance_m, :speed_ms, :started_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:duration_s, greater_than: 0)
    |> validate_number(:speed_ms, greater_than: 0)
    |> foreign_key_constraint(:activity_id)
  end

  def kinds, do: @kinds
end
