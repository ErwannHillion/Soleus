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
  alias Soleus.Training.Lap

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    activity = Training.get_activity!(id)
    series = Training.load_series(activity) || %{}

    {:ok,
     socket
     |> assign(:activity, activity)
     |> assign(:laps, Training.laps(activity))
     |> assign(:splits, Splits.per_kilometer(series))
     |> assign(:track, Splits.coordinates(series))
     |> assign(:charts, charts(series))
     |> assign(:page_title, activity.name || "Seance")}
  end

  # Les series tracables, dans l'ordre d'interet. Une serie absente du
  # fichier est simplement omise : toutes les montres n'enregistrent pas les
  # dynamiques de course, et un graphique vide ne dit rien.
  @chart_streams [
    %{
      key: :speed_ms,
      id: "stream-pace",
      title: "Allure",
      label: "allure",
      pace: true,
      color: "var(--color-signal)"
    },
    %{
      key: :hr,
      id: "stream-hr",
      title: "Frequence cardiaque",
      label: "FC",
      unit: " bpm",
      color: "var(--color-alert)"
    },
    %{
      key: :power_w,
      id: "stream-power",
      title: "Puissance",
      label: "puissance",
      unit: " W",
      color: "var(--color-fatigue)"
    },
    %{
      key: :altitude_m,
      id: "stream-altitude",
      title: "Altitude",
      label: "altitude",
      unit: " m",
      color: "var(--color-dim)"
    },
    %{
      key: :cadence,
      id: "stream-cadence",
      title: "Cadence",
      label: "cadence",
      unit: " pas/min",
      color: "var(--color-form)",
      scale: 2
    },
    %{
      key: :step_length_mm,
      id: "stream-step",
      title: "Longueur de foulee",
      label: "foulee",
      unit: " mm",
      color: "var(--color-signal-deep)"
    },
    %{
      key: :stance_time_ms,
      id: "stream-stance",
      title: "Temps de contact au sol",
      label: "contact",
      unit: " ms",
      color: "var(--color-signal-deep)"
    },
    %{
      key: :vertical_oscillation_mm,
      id: "stream-oscillation",
      title: "Oscillation verticale",
      label: "oscillation",
      unit: " mm",
      color: "var(--color-signal-deep)"
    }
  ]

  defp charts(series) do
    Enum.flat_map(@chart_streams, fn spec ->
      case Splits.resample(series, spec.key) do
        [] -> []
        points -> [Map.put(spec, :points, scale_points(points, spec[:scale]))]
      end
    end)
  end

  # La cadence est enregistree en pas d'un seul pied par minute. Le chiffre
  # que tout le monde lit est celui des deux pieds, d'ou le facteur deux.
  defp scale_points(points, nil), do: points
  defp scale_points(points, factor), do: Enum.map(points, fn {t, v} -> {t, v * factor} end)

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
              :for={stream <- @charts}
              id={stream.id}
              title={stream.title}
              points={stream.points}
              label={stream.label}
              unit={stream[:unit] || ""}
              pace={stream[:pace] || false}
              color={stream.color}
            />
          </section>
        </div>

        <.details_panel activity={@activity} />

        <%!-- Les tours enregistres par la montre priment sur une decoupe
              recalculee : ils portent l'intensite voulue par la seance et
              incluent les tours manuels. La decoupe kilometrique ne sert que
              pour les fichiers sans tours. --%>
        <.laps_panel :if={@laps != []} laps={@laps} />

        <section :if={@laps == [] and @splits != []} class="border-t border-line">
          <.panel_head title="Portions kilometriques" note={"#{length(@splits)} portions"} />
          <.splits_table splits={@splits} />
        </section>
      </main>

      <.dock current={:sessions} />
    </div>
    """
  end

  attr :laps, :list, required: true

  defp laps_panel(assigns) do
    structured? = Lap.structured?(assigns.laps)

    assigns =
      assigns
      |> assign(:structured?, structured?)
      |> assign(:summary, if(structured?, do: Lap.work_summary(assigns.laps), else: []))
      |> assign(:fastest, fastest_lap(assigns.laps))

    ~H"""
    <section class="border-t border-line">
      <.panel_head
        title={if @structured?, do: "Seance structuree", else: "Tours"}
        note={"#{length(@laps)} tours"}
      />

      <%!-- Le resume des series en tete : c'est la premiere chose qu'on
            cherche apres un fractionne, et la lire dans le tableau demande de
            reconstituer mentalement les lignes actives. --%>
      <div
        :if={@summary != []}
        class="flex flex-wrap gap-x-8 gap-y-2 border-y border-line px-5 py-3"
      >
        <div :for={block <- @summary} class="flex items-baseline gap-3">
          <span class="num text-sm text-signal">
            {block.count} x {round(block.distance_m)} m
          </span>
          <span class="num text-xs text-text">{Pace.format(block.avg_speed_ms)}/km</span>
          <span class="num text-[11px] text-faint">
            meilleur {Pace.format(block.best_speed_ms)}
            <span :if={block.avg_hr}>· FC {round(block.avg_hr)}</span>
          </span>
        </div>
      </div>

      <table class="w-full">
        <thead>
          <tr class="border-b border-line">
            <th class="label py-1.5 pl-5 text-left font-medium">tour</th>
            <th :if={@structured?} class="label py-1.5 text-left font-medium">type</th>
            <th class="label py-1.5 text-right font-medium">dist.</th>
            <th class="label py-1.5 text-right font-medium">temps</th>
            <th class="label py-1.5 pl-4 text-left font-medium">allure</th>
            <th class="label py-1.5 font-medium"></th>
            <th class="label py-1.5 text-right font-medium">FC</th>
            <th class="label py-1.5 pr-5 text-right font-medium">puiss.</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-line">
          <tr :for={lap <- @laps} class={["row-hover", Lap.work?(lap) && "bg-signal-wash/40"]}>
            <td class="num w-12 py-2 pl-5 text-[11px] text-faint">{lap.index + 1}</td>
            <td
              :if={@structured?}
              class="w-32 py-2 text-[11px]"
              style={intensity_style(lap.intensity)}
            >
              {Lap.label(lap.intensity)}
            </td>
            <td class="num w-20 py-2 text-right text-xs text-dim">{distance(lap.distance_m)}</td>
            <td class="num w-20 py-2 text-right text-xs text-dim">
              {Pace.format_duration(lap.duration_s)}
            </td>
            <td class="num w-20 py-2 pl-4 text-xs text-text">{Pace.format(lap.speed_ms)}</td>
            <td class="py-2 pr-4">
              <div class="h-1.5 bg-panel-raised">
                <div
                  class="h-full"
                  style={"width: #{lap_bar(lap, @fastest)}%; background-color: #{intensity_color(lap.intensity)}"}
                >
                </div>
              </div>
            </td>
            <td class="num w-16 py-2 text-right text-[11px] text-faint">{text(lap.avg_hr)}</td>
            <td class="num w-20 py-2 pr-5 text-right text-[11px] text-faint">
              {text(lap.avg_power)}
            </td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  attr :activity, :map, required: true

  # Les dynamiques de course et la puissance, quand la montre les enregistre.
  # Le panneau disparait entierement si rien n'est disponible : un bloc de
  # tirets n'apprend rien et occupe la place d'autre chose.
  defp details_panel(assigns) do
    assigns = assign(assigns, :has_details?, has_details?(assigns.activity))

    ~H"""
    <section :if={@has_details?} class="border-t border-line">
      <.panel_head title="Details" note="dynamiques de course et puissance" />

      <div class="grid grid-cols-2 gap-px border-t border-line bg-line sm:grid-cols-3 lg:grid-cols-6">
        <.detail
          :if={@activity.grade_adjusted_speed_ms}
          label="allure corrigee"
          value={"#{Pace.format(@activity.grade_adjusted_speed_ms)}/km"}
          note="de la pente"
        />
        <.detail
          :if={@activity.avg_power}
          label="puissance"
          value={"#{@activity.avg_power} W"}
          note={@activity.normalized_power && "normalisee #{@activity.normalized_power} W"}
        />
        <.detail
          :if={@activity.avg_cadence}
          label="cadence"
          value={"#{round(@activity.avg_cadence * 2)} pas/min"}
          note="les deux pieds"
        />
        <.detail
          :if={@activity.step_length_mm}
          label="longueur de foulee"
          value={"#{round(@activity.step_length_mm)} mm"}
        />
        <.detail
          :if={@activity.stance_time_ms}
          label="temps de contact"
          value={"#{round(@activity.stance_time_ms)} ms"}
          note="au sol"
        />
        <.detail
          :if={@activity.vertical_oscillation_mm}
          label="oscillation verticale"
          value={"#{Float.round(@activity.vertical_oscillation_mm / 10, 1)} cm"}
          note={@activity.vertical_ratio && "ratio #{@activity.vertical_ratio} %"}
        />
        <.detail
          :if={@activity.aerobic_effect}
          label="effet d'entrainement"
          value={"#{@activity.aerobic_effect} aerobie"}
          note={effect_note(@activity)}
        />
        <.detail
          :if={@activity.steps}
          label="pas"
          value={Integer.to_string(@activity.steps)}
          note={@activity.total_strides && "#{@activity.total_strides} foulees"}
        />
        <.detail
          :if={@activity.min_hr}
          label="FC minimale"
          value={"#{@activity.min_hr} bpm"}
          note="sur la seance"
        />
        <.detail
          :if={@activity.garmin_load}
          label="charge Garmin"
          value={round(@activity.garmin_load) |> Integer.to_string()}
          note={@activity.load && "Soleus #{round(@activity.load)}"}
        />
        <.detail
          :if={@activity.vo2max}
          label="VO2max"
          value={"#{@activity.vo2max}"}
          note="estimation de la montre"
        />
        <.detail
          :if={@activity.intensity_vigorous_min}
          label="minutes d'intensite"
          value={"#{@activity.intensity_vigorous_min} soutenues"}
          note={@activity.intensity_moderate_min && "#{@activity.intensity_moderate_min} moderees"}
        />
        <.detail
          :if={@activity.body_battery_delta}
          label="reserve d'energie"
          value={signed(@activity.body_battery_delta)}
          note="variation"
        />
        <.detail
          :if={@activity.max_elevation_m}
          label="altitude"
          value={"#{round(@activity.min_elevation_m)}–#{round(@activity.max_elevation_m)} m"}
          note={@activity.elevation_gain_m && "D+ #{round(@activity.elevation_gain_m)} m"}
        />
        <.detail
          :if={@activity.water_ml}
          label="perte hydrique"
          value={"#{@activity.water_ml} ml"}
          note="estimation"
        />
      </div>

      <div :if={@activity.power_zone_s} class="border-t border-line px-5 py-4">
        <div class="label mb-2">temps par zone de puissance</div>
        <.zone_bar zones={@activity.power_zone_s} class="w-full" />
      </div>
    </section>
    """
  end

  # Le libelle de Garmin est en majuscules anglaises — AEROBIC_BASE,
  # TEMPO… — ce qui jure au milieu d'une interface francaise. On le rend
  # lisible sans pretendre le traduire fidelement.
  defp effect_note(%{anaerobic_effect: anaerobic, training_effect_label: label}) do
    [anaerobic && "#{anaerobic} anaerobie", label && readable(label)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> nil
      note -> note
    end
  end

  defp readable(label) do
    label |> String.downcase() |> String.replace("_", " ")
  end

  defp signed(value) when value > 0, do: "+#{value}"
  defp signed(value), do: Integer.to_string(value)

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :note, :any, default: nil

  defp detail(assigns) do
    ~H"""
    <div class="bg-ink px-5 py-4">
      <div class="label">{@label}</div>
      <div class="num mt-1.5 text-lg leading-none text-text">{@value}</div>
      <div :if={@note} class="mt-1.5 text-[10px] text-faint">{@note}</div>
    </div>
    """
  end

  @detail_fields ~w(
    grade_adjusted_speed_ms avg_power step_length_mm stance_time_ms
    vertical_oscillation_mm aerobic_effect steps min_hr garmin_load vo2max
    intensity_vigorous_min body_battery_delta max_elevation_m water_ml
    power_zone_s
  )a

  defp has_details?(activity) do
    Enum.any?(@detail_fields, &(not is_nil(Map.get(activity, &1))))
  end

  defp intensity_color("active"), do: "var(--color-signal)"
  defp intensity_color("recovery"), do: "var(--color-form)"
  defp intensity_color("rest"), do: "var(--color-form)"
  defp intensity_color("warmup"), do: "var(--color-line-bright)"
  defp intensity_color("cooldown"), do: "var(--color-line-bright)"
  defp intensity_color(_other), do: "var(--color-signal-deep)"

  defp intensity_style(intensity), do: "color: #{intensity_color(intensity)}"

  defp fastest_lap(laps) do
    laps |> Enum.map(& &1.speed_ms) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> 1.0 end)
  end

  # Les barres sont rapportees au tour le plus rapide, et non etalees entre le
  # plus lent et le plus rapide comme pour les portions kilometriques. La
  # raison tient a la nature des donnees : une seance a series melange des
  # trottes a 10:00/km et des series a 4:00/km, et etaler cet ecart ecraserait
  # toutes les series les unes sur les autres.
  defp lap_bar(%{speed_ms: nil}, _fastest), do: 0

  defp lap_bar(%{speed_ms: speed}, fastest) when fastest > 0 do
    (speed / fastest * 100) |> max(4.0) |> min(100.0) |> Float.round(1)
  end

  defp lap_bar(_lap, _fastest), do: 0

  defp distance(nil), do: "—"
  defp distance(meters) when meters >= 1000, do: "#{Float.round(meters / 1000, 2)} km"
  defp distance(meters), do: "#{round(meters)} m"

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
