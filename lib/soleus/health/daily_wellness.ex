defmodule Soleus.Health.DailyWellness do
  @moduledoc """
  Une journee de mesures physiologiques hors seance.

  Ce que la montre enregistre en continu : sommeil, variabilite cardiaque,
  frequence au repos, respiration, stress, reserve d'energie, pas.

  ## Les lignes de base

  Plusieurs mesures sont accompagnees de leurs bornes personnelles et d'un
  statut (`hr_baseline_low/high`, `hrv_baseline_*`...). Elles viennent de
  Garmin, qui les etablit sur plusieurs semaines d'historique propre a
  l'athlete.

  C'est ce qui separe une donnee d'une information : 57 battements au repos ne
  veulent rien dire. Savoir que la normale de cet athlete est 50 a 69 et qu'on
  est donc dans la fourchette, si. Soleus ne recalcule pas ces bornes — les
  reproduire a l'aveugle donnerait des seuils moins bons que ceux etablis sur
  l'historique complet de l'appareil.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:date, :date, autogenerate: false}

  @fields ~w(
    date
    resting_hr hr_baseline_low hr_baseline_high hr_status
    hrv_overnight hrv_baseline_low hrv_baseline_high hrv_status hrv_weekly_avg
    respiration_avg respiration_low respiration_high spo2_avg spo2_status
    skin_temp_delta skin_temp_status
    sleep_total_s sleep_deep_s sleep_light_s sleep_rem_s sleep_awake_s
    sleep_score sleep_quality_score sleep_recovery_score sleep_start sleep_end
    body_battery_high body_battery_low body_battery_charged body_battery_drained
    stress_avg stress_max stress_rest_s
    steps steps_goal floors active_seconds calories_total calories_active
    intensity_moderate_min intensity_vigorous_min distance_m
    training_readiness recovery_time_h
    garmin_acute_load garmin_chronic_load garmin_acwr garmin_acwr_status
    training_status vo2max endurance_score hill_score
  )a

  schema "daily_wellness" do
    field :resting_hr, :integer
    field :hr_baseline_low, :integer
    field :hr_baseline_high, :integer
    field :hr_status, :string

    field :hrv_overnight, :float
    field :hrv_baseline_low, :float
    field :hrv_baseline_high, :float
    field :hrv_status, :string
    field :hrv_weekly_avg, :float

    field :respiration_avg, :float
    field :respiration_low, :float
    field :respiration_high, :float
    field :spo2_avg, :float
    field :spo2_status, :string

    field :skin_temp_delta, :float
    field :skin_temp_status, :string

    field :sleep_total_s, :integer
    field :sleep_deep_s, :integer
    field :sleep_light_s, :integer
    field :sleep_rem_s, :integer
    field :sleep_awake_s, :integer
    field :sleep_score, :integer
    field :sleep_quality_score, :integer
    field :sleep_recovery_score, :integer
    field :sleep_start, :utc_datetime
    field :sleep_end, :utc_datetime

    field :body_battery_high, :integer
    field :body_battery_low, :integer
    field :body_battery_charged, :integer
    field :body_battery_drained, :integer
    field :stress_avg, :integer
    field :stress_max, :integer
    field :stress_rest_s, :integer

    field :steps, :integer
    field :steps_goal, :integer
    field :floors, :float
    field :active_seconds, :integer
    field :calories_total, :integer
    field :calories_active, :integer
    field :intensity_moderate_min, :integer
    field :intensity_vigorous_min, :integer
    field :distance_m, :float

    field :training_readiness, :integer
    field :recovery_time_h, :float
    field :garmin_acute_load, :float
    field :garmin_chronic_load, :float
    field :garmin_acwr, :float
    field :garmin_acwr_status, :string
    field :training_status, :string
    field :vo2max, :float
    field :endurance_score, :integer
    field :hill_score, :integer

    timestamps(type: :utc_datetime)
  end

  @doc "Champs acceptes, exposes pour l'upsert en masse de l'import."
  def fields, do: @fields

  def changeset(wellness, attrs) do
    wellness
    |> cast(attrs, @fields)
    |> validate_required([:date])
  end

  @doc """
  Situe une mesure par rapport a ses bornes personnelles.

  Rend `:low`, `:in_range`, `:high` ou `:unknown`. On recalcule plutot que de
  reprendre le statut textuel de Garmin : celui-ci est parfois `UNKNOWN` alors
  que la valeur et les bornes sont toutes les deux presentes.
  """
  @spec situate(number() | nil, number() | nil, number() | nil) ::
          :low | :in_range | :high | :unknown
  def situate(value, low, high)
      when is_number(value) and is_number(low) and is_number(high) and high > low do
    cond do
      value < low -> :low
      value > high -> :high
      true -> :in_range
    end
  end

  def situate(_value, _low, _high), do: :unknown

  @doc """
  Position d'une valeur dans sa fourchette, entre 0 et 1.

  Sert a placer un curseur sur une jauge. Bornee pour qu'une valeur hors
  fourchette reste visible au bord plutot que de sortir du cadre.
  """
  @spec position(number() | nil, number() | nil, number() | nil) :: float() | nil
  def position(value, low, high)
      when is_number(value) and is_number(low) and is_number(high) and high > low do
    ((value - low) / (high - low)) |> max(-0.15) |> min(1.15)
  end

  def position(_value, _low, _high), do: nil
end
