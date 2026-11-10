defmodule Soleus.Training.Activity do
  @moduledoc """
  Une seance : les totaux, et les metriques que le moteur d'analyse en tire.

  Les series point par point vivent dans `Soleus.Training.Stream`, charge a la
  demande. La separation est deliberee : une liste d'activites n'a jamais
  besoin des 3 600 points de chaque sortie, et les garder dans la meme table
  rendrait chaque requete de liste couteuse.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @sources ~w(fit_import garmin_api strava manual)
  @sports ~w(run ride swim walk hike strength unknown)

  schema "activities" do
    field :source, :string
    field :external_id, :string
    field :fit_digest, :string
    field :fit_path, :string

    field :sport, :string
    field :name, :string
    field :notes, :string
    field :started_at, :utc_datetime
    field :local_date, :date

    field :distance_m, :float
    field :moving_time_s, :integer
    field :elapsed_time_s, :integer
    field :elevation_gain_m, :float
    field :calories, :integer

    field :avg_hr, :integer
    field :max_hr, :integer
    field :avg_cadence, :float
    field :avg_speed_ms, :float
    field :max_speed_ms, :float

    field :trimp, :float
    field :load, :float
    field :decoupling, :float
    field :intensity_factor, :float
    field :hr_zone_s, {:array, :integer}

    field :avg_power, :integer
    field :max_power, :integer
    field :normalized_power, :integer
    field :vertical_oscillation_mm, :float
    field :stance_time_ms, :float
    field :step_length_mm, :float
    field :vertical_ratio, :float
    field :aerobic_effect, :float
    field :anaerobic_effect, :float
    field :total_strides, :integer
    field :grade_adjusted_speed_ms, :float
    field :min_hr, :integer
    field :steps, :integer
    field :min_elevation_m, :float
    field :max_elevation_m, :float
    field :garmin_load, :float
    field :vo2max, :float
    field :training_effect_label, :string
    field :intensity_moderate_min, :integer
    field :intensity_vigorous_min, :integer
    field :body_battery_delta, :integer
    field :bmr_calories, :integer
    field :water_ml, :integer
    field :power_zone_s, {:array, :integer}

    field :analyzed_at, :utc_datetime

    has_one :stream, Soleus.Training.Stream
    has_many :best_efforts, Soleus.Training.BestEffort
    has_many :laps, Soleus.Training.Lap

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset d'ingestion : tout ce qui vient du fichier ou de l'API."
  def ingest_changeset(activity, attrs) do
    activity
    |> cast(attrs, [
      :source,
      :external_id,
      :fit_digest,
      :fit_path,
      :sport,
      :name,
      :notes,
      :started_at,
      :local_date,
      :distance_m,
      :moving_time_s,
      :elapsed_time_s,
      :elevation_gain_m,
      :calories,
      :avg_hr,
      :max_hr,
      :avg_cadence,
      :avg_speed_ms,
      :max_speed_ms,
      :avg_power,
      :max_power,
      :normalized_power,
      :vertical_oscillation_mm,
      :stance_time_ms,
      :step_length_mm,
      :vertical_ratio,
      :aerobic_effect,
      :anaerobic_effect,
      :total_strides,
      :grade_adjusted_speed_ms,
      :min_hr,
      :steps,
      :min_elevation_m,
      :max_elevation_m,
      :garmin_load,
      :vo2max,
      :training_effect_label,
      :intensity_moderate_min,
      :intensity_vigorous_min,
      :body_battery_delta,
      :bmr_calories,
      :water_ml,
      :power_zone_s
    ])
    |> put_local_date()
    |> validate_required([:source, :sport, :started_at, :local_date])
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:sport, @sports)
    |> validate_number(:distance_m, greater_than_or_equal_to: 0)
    |> validate_number(:moving_time_s, greater_than_or_equal_to: 0)
    |> unique_constraint(:fit_digest)
    |> unique_constraint([:source, :external_id])
  end

  @doc "Changeset des metriques derivees, pose par le moteur d'analyse."
  def metrics_changeset(activity, attrs) do
    activity
    |> cast(attrs, [
      :trimp,
      :load,
      :decoupling,
      :intensity_factor,
      :hr_zone_s,
      :analyzed_at,
      :avg_power,
      :max_power,
      :normalized_power,
      :vertical_oscillation_mm,
      :stance_time_ms,
      :step_length_mm,
      :vertical_ratio,
      :aerobic_effect,
      :anaerobic_effect,
      :total_strides,
      :grade_adjusted_speed_ms,
      :min_hr,
      :steps,
      :min_elevation_m,
      :max_elevation_m,
      :garmin_load,
      :vo2max,
      :training_effect_label,
      :intensity_moderate_min,
      :intensity_vigorous_min,
      :body_battery_delta,
      :bmr_calories,
      :water_ml,
      :power_zone_s
    ])
  end

  # La date locale est la cle de l'agregation quotidienne et de tous les
  # graphes de charge. On la derive du depart plutot que de la demander, pour
  # qu'une activite ne puisse pas se retrouver rangee un autre jour que celui
  # ou elle a ete courue.
  defp put_local_date(changeset) do
    case {get_field(changeset, :local_date), get_field(changeset, :started_at)} do
      {nil, %DateTime{} = at} -> put_change(changeset, :local_date, DateTime.to_date(at))
      _ -> changeset
    end
  end

  def sources, do: @sources
  def sports, do: @sports
end
