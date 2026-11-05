defmodule SoleusWeb.ActivityLive do
  @moduledoc """
  Le detail d'une seance : trace, series, portions kilometriques.

  C'est la seule page qui lit les series point par point. Elles sont
  reechantillonnees par `Soleus.Analytics.Splits` avant affichage — voir ce
  module pour la raison, qui tient en un chiffre : une sortie d'une heure
  porte 3 600 points par serie, et l'oeil n'en distingue pas le dixieme.
  """

  use SoleusWeb, :live_view

  import SoleusWeb.Charts
  import SoleusWeb.Dock

  alias Soleus.Analytics.{Decoupling, Load, Pace, Splits}
  alias Soleus.Training

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    activity = Training.get_activity!(id)
    series = Training.load_series(activity) || %{}

    {:ok,
     socket
     |> assign(:activity, activity)
     |> assign(:splits, Splits.per_kilometer(series))
     |> assign(:track, Splits.coordinates(series))
     |> assign(:speed, Splits.resample(series, :speed_ms))
     |> assign(:hr, Splits.resample(series, :hr))
     |> assign(:altitude, Splits.resample(series, :altitude_m))
     |> assign(:page_title, activity.name || "Seance")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-dvh flex-col overflow-hidden bg-ink">
      <header class="flex shrink-0 items-baseline justify-between border-b border-line px-5 py-3">
        <div class="flex items-baseline gap-3">
          <.link navigate={~p"/seances"} class="text-faint transition-colors hover:text-text">
            <span class="hero-arrow-left h-3.5 w-3.5 bg-current" />
          </.link>
          <h1 class="text-sm font-semibold tracking-[0.1em] text-text">
            {@activity.name || "Seance"}
          </h1>
          <span class="label">{long_date(@activity.local_date)}</span>
        </div>
        <span class="num text-[11px] text-faint">{@activity.sport}</span>
      </header>

      <main class="flex-1 overflow-y-auto pb-28">
        <div class="grid grid-cols-2 divide-x divide-line border-b border-line md:grid-cols-4 xl:grid-cols-8">
          <.stat label="distance" value={km(@activity.distance_m)} unit="km" signal />
          <.stat label="temps" value={Pace.format_duration(@activity.moving_time_s)} />
          <.stat label="allure" value={Pace.format(@activity.avg_speed_ms)} unit="/km" />
          <.stat label="FC moyenne" value={text(@activity.avg_hr)} unit="bpm" />
          <.stat label="FC max" value={text(@activity.max_hr)} unit="bpm" />
          <.stat label="D+" value={text(@activity.elevation_gain_m, 0)} unit="m" />
          <.stat label="charge" value={text(@activity.load, 0)} />
          <.stat label="derive" value={decoupling(@activity.decoupling)} />
        </div>

        <div class="grid grid-cols-1 divide-y divide-line xl:grid-cols-12 xl:divide-x xl:divide-y-0">
          <section class="xl:col-span-4">
            <.panel_head title="Trace" note={gps_note(@track)} />
            <div class="px-5 pb-5">
              <%!-- `id` stable et `phx-update="ignore"` : Leaflet construit son
                    propre arbre DOM dans ce noeud, et laisser LiveView le
                    reconcilier le detruirait a chaque rendu. --%>
              <div
                :if={@track != []}
                id={"track-#{@activity.id}"}
                phx-hook="TrackMap"
                phx-update="ignore"
                data-track={Jason.encode!(@track)}
                class="h-[26rem] w-full border border-line"
              >
              </div>
              <p :if={@track == []} class="py-8 text-center text-xs text-faint">
                Aucun point GPS sur cette seance
              </p>
            </div>
          </section>

          <section class="xl:col-span-8">
            <.stream_panel
              :if={@speed != []}
              id="stream-pace"
              title="Allure"
              points={@speed}
              label="allure"
              pace
              color="var(--color-signal)"
            />
            <.stream_panel
              :if={@hr != []}
              id="stream-hr"
              title="Frequence cardiaque"
              points={@hr}
              label="FC"
              unit=" bpm"
              color="var(--color-alert)"
            />
            <.stream_panel
              :if={@altitude != []}
              id="stream-altitude"
              title="Altitude"
              points={@altitude}
              label="altitude"
              unit=" m"
              color="var(--color-fatigue)"
            />
          </section>
        </div>

        <section :if={@splits != []} class="border-t border-line">
          <.panel_head title="Portions kilometriques" note={"#{length(@splits)} portions"} />
          <.splits_table splits={@splits} />
        </section>
      </main>

      <.dock current={:sessions} />
    </div>
    """
  end

  attr :splits, :list, required: true

  defp splits_table(assigns) do
    # L'echelle des barres va de la portion la plus lente a la plus rapide, et
    # non de zero a la plus rapide. Sur une sortie reguliere, toutes les
    # portions tiennent dans dix pour cent les unes des autres : rapportees a
    # zero, leurs barres seraient visuellement identiques et n'apprendraient
    # rien. Etalees sur l'ecart reel, elles montrent ce qu'on vient chercher —
    # ou on a accelere, ou on a lache.
    speeds = assigns.splits |> Enum.map(& &1.speed_ms) |> Enum.reject(&is_nil/1)
    {slowest, fastest} = Enum.min_max(speeds, fn -> {1.0, 1.0} end)

    assigns = assign(assigns, slowest: slowest, fastest: fastest)

    ~H"""
    <table class="w-full">
      <thead>
        <tr class="border-b border-line">
          <th class="label py-1.5 pl-5 text-left font-medium">km</th>
          <th class="label py-1.5 text-left font-medium">allure</th>
          <th class="label py-1.5 font-medium"></th>
          <th class="label py-1.5 text-right font-medium">cumule</th>
          <th class="label py-1.5 pr-5 text-right font-medium">FC</th>
        </tr>
      </thead>
      <tbody class="divide-y divide-line">
        <tr :for={split <- @splits} class="row-hover">
          <td class="num w-14 py-2 pl-5 text-[11px] text-faint">
            {split.index}{if split.partial?, do: "*", else: ""}
          </td>
          <td class="num w-20 py-2 text-xs text-text">{Pace.format(split.speed_ms)}</td>
          <td class="py-2 pr-5">
            <div class="h-1.5 bg-panel-raised">
              <div
                class="h-full bg-signal"
                style={"width: #{bar_width(split.speed_ms, @slowest, @fastest)}%"}
              >
              </div>
            </div>
          </td>
          <td class="num w-24 py-2 text-right text-[11px] text-dim">
            {Pace.format_duration(split.from_s + split.duration_s)}
          </td>
          <td class="num w-20 py-2 pr-5 text-right text-[11px] text-faint">
            {text(split.avg_hr)}
          </td>
        </tr>
      </tbody>
    </table>
    <p :if={Enum.any?(@splits, & &1.partial?)} class="px-5 pb-4 pt-2 text-[10px] text-faint">
      * portion incomplete
    </p>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :points, :list, required: true
  attr :label, :string, required: true
  attr :unit, :string, default: ""
  attr :color, :string, default: "var(--color-signal)"
  attr :pace, :boolean, default: false

  defp stream_panel(assigns) do
    ~H"""
    <div class="border-b border-line last:border-b-0">
      <.panel_head title={@title} />
      <div class="px-5 pb-4">
        <.stream_chart
          id={@id}
          points={@points}
          label={@label}
          unit={@unit}
          color={@color}
          pace={@pace}
          class="w-full"
        />
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :note, :any, default: nil

  defp panel_head(assigns) do
    ~H"""
    <div class="flex items-baseline justify-between px-5 pb-3 pt-4">
      <h2 class="text-[11px] font-semibold uppercase tracking-[0.14em] text-text">{@title}</h2>
      <span :if={@note} class="label">{@note}</span>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :unit, :string, default: nil
  attr :signal, :boolean, default: false

  defp stat(assigns) do
    ~H"""
    <div class={["px-4 py-4", @signal && "panel-signal"]}>
      <div class="label">{@label}</div>
      <div class="mt-1.5 flex items-baseline gap-1">
        <span class={["num text-xl leading-none", if(@signal, do: "text-signal", else: "text-text")]}>
          {@value}
        </span>
        <span :if={@unit} class="text-[10px] text-faint">{@unit}</span>
      </div>
    </div>
    """
  end

  defp bar_width(nil, _slowest, _fastest), do: 0

  # Plancher a 12 % : la portion la plus lente doit rester visible, sinon une
  # sortie reguliere afficherait une barre vide sur sa ligne la plus lente, ce
  # qui se lit comme une donnee manquante.
  defp bar_width(speed, slowest, fastest) when fastest > slowest do
    (12 + (speed - slowest) / (fastest - slowest) * 88) |> Float.round(1)
  end

  defp bar_width(_speed, _slowest, _fastest), do: 100

  defp km(nil), do: "—"
  defp km(meters), do: (meters / 1000) |> Float.round(2) |> to_string()

  defp text(value, precision \\ 1)
  defp text(nil, _precision), do: "—"
  defp text(value, 0) when is_number(value), do: value |> round() |> Integer.to_string()
  defp text(value, _precision) when is_integer(value), do: Integer.to_string(value)

  defp text(value, precision) when is_number(value),
    do: value |> Float.round(precision) |> to_string()

  defp decoupling(nil), do: "—"

  defp decoupling(percent) do
    {_state, _label} = Decoupling.interpret(percent)
    sign = if percent >= 0, do: "+", else: ""
    "#{sign}#{Float.round(percent, 1)} %"
  end

  defp gps_note([]), do: "aucun point GPS"
  defp gps_note(points), do: "#{length(points)} points · OpenStreetMap"

  @months ~w(janvier fevrier mars avril mai juin juillet aout septembre octobre novembre decembre)

  defp long_date(date), do: "#{date.day} #{Enum.at(@months, date.month - 1)} #{date.year}"

  # Rappel que ce module n'utilise pas la charge, mais que l'alias doit rester
  # coherent avec le reste du code si on l'ajoute.
  _ = Load
end
