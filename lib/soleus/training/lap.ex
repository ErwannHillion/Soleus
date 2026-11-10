defmodule Soleus.Training.Lap do
  @moduledoc """
  Un tour, tel que la montre l'a enregistre.

  L'interet tient a un seul champ : `intensity`. La montre connaissait la
  seance programmee, elle sait donc si un tour est un echauffement, une serie,
  une recuperation ou un retour au calme. Aucune decoupe recalculee apres coup
  ne retrouverait cela — une serie de quatre cents metres et la trotte qui la
  suit se ressemblent trop sur les seules mesures.
  """

  use Ecto.Schema
  import Ecto.Changeset

  # Les valeurs ecrites par Garmin. On les conserve telles quelles plutot que
  # de les traduire : ce sont les memes mots que l'athlete voit dans Connect.
  @intensities ~w(warmup active recovery rest cooldown interval)

  schema "activity_laps" do
    belongs_to :activity, Soleus.Training.Activity

    field :index, :integer
    field :intensity, :string
    field :trigger, :string

    field :start_offset_s, :integer
    field :duration_s, :float
    field :elapsed_s, :float
    field :distance_m, :float
    field :speed_ms, :float

    field :avg_hr, :integer
    field :max_hr, :integer
    field :avg_cadence, :float
    field :avg_power, :integer
    field :max_power, :integer
    field :normalized_power, :integer
    field :ascent_m, :float
    field :descent_m, :float

    field :vertical_oscillation_mm, :float
    field :stance_time_ms, :float
    field :step_length_mm, :float
    field :vertical_ratio, :float

    timestamps(type: :utc_datetime)
  end

  @fields ~w(
    activity_id index intensity trigger start_offset_s duration_s elapsed_s
    distance_m speed_ms avg_hr max_hr avg_cadence avg_power max_power
    normalized_power ascent_m descent_m vertical_oscillation_mm stance_time_ms
    step_length_mm vertical_ratio
  )a

  def fields, do: @fields

  def changeset(lap, attrs) do
    lap
    |> cast(attrs, @fields)
    |> validate_required([:activity_id, :index])
    |> unique_constraint([:activity_id, :index])
    |> foreign_key_constraint(:activity_id)
  end

  @doc """
  Les tours de travail : les series, sans les trottes ni les kilometres
  automatiques.

  Seul `active` compte. `interval` serait tentant, mais Garmin l'emploie
  comme valeur **par defaut** des tours automatiques : sur l'historique
  present, 761 tours portent `interval` avec un declencheur `distance`, et ce
  sont les kilometres d'un footing ordinaire. Les compter comme du travail
  ferait passer chaque sortie pour une seance a series.
  """
  @spec work?(%__MODULE__{}) :: boolean()
  def work?(%__MODULE__{intensity: "active"}), do: true
  def work?(%__MODULE__{}), do: false

  @doc "Les tours de recuperation."
  @spec recovery?(%__MODULE__{}) :: boolean()
  def recovery?(%__MODULE__{intensity: intensity}), do: intensity in ~w(recovery rest)

  @doc """
  La seance comporte-t-elle un travail structure ?

  Le marqueur est la presence d'une intensite **autre** que `interval` : des
  que la montre distingue echauffement, serie, recuperation ou retour au
  calme, c'est qu'elle suivait une seance programmee. Un footing n'a que des
  tours `interval`.
  """
  @spec structured?([%__MODULE__{}]) :: boolean()
  def structured?(laps), do: Enum.any?(laps, &(&1.intensity not in [nil, "interval"]))

  @doc """
  Resume des series d'une seance structuree, facon « 6 x 400 m a 4:07/km ».

  Les series sont regroupees par distance arrondie aux cinquante metres : une
  serie de quatre cents metres mesuree a 398 et une autre a 402 sont la meme
  serie, et les separer donnerait un resume illisible.
  """
  @spec work_summary([%__MODULE__{}]) :: [map()]
  def work_summary(laps) do
    laps
    |> Enum.filter(&work?/1)
    |> Enum.group_by(&bucket/1)
    |> Enum.map(fn {bucket, group} ->
      speeds = group |> Enum.map(& &1.speed_ms) |> Enum.reject(&is_nil/1)

      %{
        count: length(group),
        distance_m: bucket,
        avg_speed_ms: mean(speeds),
        best_speed_ms: Enum.max(speeds, fn -> nil end),
        avg_hr: group |> Enum.map(& &1.avg_hr) |> Enum.reject(&is_nil/1) |> mean()
      }
    end)
    |> Enum.sort_by(& &1.distance_m)
  end

  defp bucket(%__MODULE__{distance_m: nil}), do: 0
  defp bucket(%__MODULE__{distance_m: distance}), do: round(distance / 50) * 50

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)

  @doc "Les intensites reconnues."
  def intensities, do: @intensities

  @doc "Libelle lisible d'une intensite."
  def label("warmup"), do: "echauffement"
  def label("active"), do: "serie"
  def label("interval"), do: "serie"
  def label("recovery"), do: "recuperation"
  def label("rest"), do: "repos"
  def label("cooldown"), do: "retour au calme"
  def label(other), do: other || "tour"
end
