defmodule SoleusWeb.PlanLive do
  @moduledoc """
  Plan d'entrainement vers une course datee.

  Le formulaire se met a jour a chaque frappe plutot qu'a la validation : les
  parametres interagissent — un objectif hors de portee sur douze semaines
  devient atteignable sur seize — et voir le verdict bouger en changeant la
  date vaut mieux que de le decouvrir apres coup.
  """

  use SoleusWeb, :live_view

  import SoleusWeb.Dock
  import SoleusWeb.Viz

  alias Soleus.Analytics.Pace
  alias Soleus.Coaching.{Feasibility, Plan, Target}

  # Distances proposees, avec leur denivele usuel a titre indicatif. L'athlete
  # reste libre de saisir ce qu'il veut.
  @distances [
    {"5 km", 5_000},
    {"10 km", 10_000},
    {"Semi", 21_097},
    {"Marathon", 42_195}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Plan")
     |> assign(:params, default_params())
     |> compute()}
  end

  @impl true
  def handle_event("change", params, socket) do
    merged =
      Map.merge(socket.assigns.params, %{
        date: params["date"] || "",
        distance: params["distance"] || "",
        elevation: params["elevation"] || "",
        target: params["target"] || ""
      })

    {:noreply, socket |> assign(:params, merged) |> compute()}
  end

  def handle_event("preset", %{"distance" => distance}, socket) do
    params = Map.put(socket.assigns.params, :distance, distance)
    {:noreply, socket |> assign(:params, params) |> compute()}
  end

  # -- calcul ------------------------------------------------------------------

  defp default_params do
    %{
      date: Date.utc_today() |> Date.add(84) |> Date.to_iso8601(),
      distance: "10000",
      elevation: "0",
      target: ""
    }
  end

  defp compute(socket) do
    params = socket.assigns.params

    with {:ok, date} <- parse_date(params.date),
         {:ok, distance} <- parse_number(params.distance),
         true <- distance > 0 do
      build(socket, date, distance, parse_number(params.elevation), params.target)
    else
      _invalid ->
        assign(socket,
          assessment: nil,
          plan: nil,
          weeks: 0,
          error: "Renseigne une date et une distance"
        )
    end
  end

  defp build(socket, date, distance, elevation, raw_target) do
    # Arithmetique entiere de bout en bout. La division flottante suivie d'un
    # `max(..., 0)` rendait l'entier 0 pour une date passee, que
    # `Float.floor/2` refuse — la page plantait au lieu de dire simplement
    # qu'il n'y a pas de temps devant.
    weeks = date |> Date.diff(Date.utc_today()) |> div(7) |> max(0)

    elevation =
      case elevation do
        {:ok, value} -> value
        _absent -> nil
      end

    case Target.parse(raw_target) do
      :error ->
        assign(socket,
          assessment: nil,
          plan: nil,
          weeks: weeks,
          error: "Temps cible incomprehensible"
        )

      parsed ->
        target = if parsed == :none, do: nil, else: elem(parsed, 1)
        effective = Target.effective_distance(distance, elevation)
        assessment = Feasibility.assess(effective, target, weeks)

        # L'allure specifique du plan vise le temps **atteignable**, pas le
        # temps souhaite : s'entrainer a une allure qu'on ne tiendra pas le
        # jour J est le meilleur moyen de rater la course et de se blesser
        # avant.
        goal_time = target_or_achievable(target, assessment)
        race_pace = goal_time && distance / goal_time

        socket
        |> assign(:assessment, assessment)
        |> assign(:plan, Plan.build(%{weeks: weeks, sport: "run", race_pace_ms: race_pace}))
        |> assign(:weeks, weeks)
        |> assign(:race, %{
          date: date,
          distance: distance,
          elevation: elevation || 0,
          effective: effective
        })
        |> assign(:goal_time, goal_time)
        |> assign(:error, nil)
    end
  end

  defp target_or_achievable(nil, assessment), do: assessment.achievable_time_s

  defp target_or_achievable(target, %{verdict: verdict})
       when verdict in [:reached, :reachable, :tight],
       do: target

  defp target_or_achievable(_target, %{achievable_time_s: achievable}), do: achievable

  defp parse_date(""), do: :error
  defp parse_date(raw), do: Date.from_iso8601(raw)

  defp parse_number(nil), do: :error
  defp parse_number(""), do: :error

  defp parse_number(raw) do
    case Float.parse(raw) do
      {value, _rest} -> {:ok, value}
      :error -> :error
    end
  end

  # -- rendu -------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-dvh flex-col overflow-hidden bg-ink">
      <header class="flex shrink-0 items-center justify-between px-5 pb-1 pt-4">
        <div class="flex items-center gap-3">
          <span class="flex h-8 w-8 items-center justify-center rounded-[0.6rem] bg-signal">
            <span class="hero-bolt-solid h-4.5 w-4.5 bg-ink"></span>
          </span>
          <div class="leading-none">
            <h1 class="display text-[1.375rem] uppercase italic tracking-wide text-text">
              Soleus
            </h1>
            <span class="text-[11px] font-medium text-faint">Plan d'entrainement</span>
          </div>
        </div>
        <span :if={@weeks > 0} class="chip">{@weeks} semaines</span>
      </header>

      <main class="board flex-1 overflow-y-auto pb-28">
        <form id="plan-form" phx-change="change" class="card px-5 py-4">
          <div class="flex flex-wrap items-end gap-x-8 gap-y-4">
            <.field label="Date de course">
              <input type="date" name="date" value={@params.date} class={input_class()} />
            </.field>

            <.field label="Distance (m)">
              <div class="flex items-center gap-2">
                <input type="number" name="distance" value={@params.distance} class={input_class()} />
                <button
                  :for={{label, meters} <- distances()}
                  type="button"
                  phx-click="preset"
                  phx-value-distance={meters}
                  class={[
                    "segment border border-line",
                    @params.distance == to_string(meters) && "segment-active border-signal"
                  ]}
                >
                  {label}
                </button>
              </div>
            </.field>

            <.field label="Denivele positif (m)">
              <input type="number" name="elevation" value={@params.elevation} class={input_class()} />
            </.field>

            <.field label="Temps cible">
              <input
                type="text"
                name="target"
                value={@params.target}
                placeholder="sub 50, 1h45, 22:49..."
                class={[input_class(), "w-40"]}
              />
            </.field>
          </div>

          <p class="mt-3 text-[11px] text-faint">
            Le temps cible est facultatif. Sans lui, l'objectif est deduit de ta
            forme actuelle et du temps disponible.
          </p>
        </form>

        <p :if={@error} class="card px-5 py-8 text-xs text-faint">{@error}</p>

        <.assessment_panel
          :if={@assessment && @weeks > 0}
          assessment={@assessment}
          race={@race}
          goal_time={@goal_time}
          target={@params.target}
        />

        <.plan_table :if={@plan && @plan.weeks != []} plan={@plan} race={@race} />
      </main>

      <.dock current={:plan} />
    </div>
    """
  end

  attr :assessment, :map, required: true
  attr :race, :map, required: true
  attr :goal_time, :any, default: nil
  attr :target, :string, default: ""

  defp assessment_panel(assigns) do
    ~H"""
    <section class={["card border-t-[3px]", verdict_bar(@assessment.verdict)]}>
      <div class="grid grid-cols-2 gap-2 px-4 pt-4 md:grid-cols-4">
        <.stat
          label="verdict"
          value={Feasibility.explain(@assessment.verdict)}
          tone={verdict_tone(@assessment.verdict)}
          small
        />
        <.stat label="objectif retenu" value={Pace.format_duration(@goal_time)} tone="signal" />
        <.stat
          label="allure visee"
          value={@goal_time && "#{Pace.format(@race.distance / @goal_time)}/km"}
        />
        <.stat
          label="vitesse critique"
          value={"#{number(@assessment.current_cs, 3)} → #{number(@assessment.required_cs || projected(@assessment), 3)}"}
          note="actuelle vers requise, en m/s"
        />
      </div>

      <div class="grid grid-cols-1 gap-x-8 gap-y-3 px-5 py-4 lg:grid-cols-3">
        <p class="max-w-prose text-[11px] leading-relaxed text-faint">
          <span :if={@race.elevation > 0}>
            Les {round(@race.elevation)} m de denivele sont comptes comme {Float.round(
              @race.elevation * Target.climb_factor() / 1000,
              1
            )} km de plat
            supplementaires, soit une distance equivalente de {Float.round(@race.effective / 1000, 1)} km.
          </span>
          <span :if={@race.elevation == 0}>Parcours considere comme plat.</span>
        </p>

        <p class="max-w-prose text-[11px] leading-relaxed text-faint">
          <span :if={@assessment.gain_source == :personal}>
            Progression estimee a partir de <strong class="text-dim">ta</strong>
            tendance mesuree : {Float.round(@assessment.weekly_gain * 100, 2)} % de vitesse
            critique par semaine.
          </span>
          <span :if={@assessment.gain_source == :generic}>
            Ton historique ne porte pas de tendance exploitable, donc la
            progression retenue est <strong class="text-dim">generique</strong> et
            conservatrice ({Float.round(@assessment.weekly_gain * 100, 2)} % par semaine).
            A prendre comme un ordre de grandeur, pas comme une prevision.
          </span>
        </p>

        <p
          :if={@assessment.verdict == :out_of_reach and @target != ""}
          class="max-w-prose text-[11px] leading-relaxed"
          style="color: var(--color-fatigue)"
        >
          Il faudrait {round(@assessment.weeks_needed)} semaines pour atteindre ce
          temps, contre {@assessment.weeks_available} disponibles. Le plan ci-dessous
          vise donc {Pace.format_duration(@assessment.achievable_time_s)}, qui est ce
          que la progression permet reellement.
        </p>
      </div>
    </section>
    """
  end

  attr :plan, :map, required: true
  attr :race, :map, required: true

  defp plan_table(assigns) do
    ~H"""
    <section class="card">
      <div class="flex items-baseline justify-between gap-4 px-5 pb-3 pt-4">
        <h2 class="text-sm font-semibold text-text">Les seances</h2>
        <span class="text-[11px] font-medium text-faint">
          {@plan.frequency} par semaine · charge {round(@plan.start_weekly_load)} → {round(
            @plan.peak_weekly_load
          )}
        </span>
      </div>

      <div class="px-5 pb-2">
        <.bars bars={load_bars(@plan.weeks)} height="h-32" />
        <div class="mt-3 flex flex-wrap gap-x-5 gap-y-1">
          <span
            :for={{phase, label} <- Plan.phase_labels()}
            class="flex items-center gap-1.5 text-[11px] text-faint"
          >
            <span class="h-2 w-2 rounded-full" style={"background-color: #{phase_color(phase)}"}></span>
            {label}
          </span>
        </div>
      </div>

      <div class="grid grid-cols-1 gap-2 px-4 pb-2 pt-3 lg:grid-cols-2 2xl:grid-cols-3">
        <article
          :for={week <- @plan.weeks}
          class="tile rise overflow-hidden"
          style={"--i: #{min(week.index, 10)}; border-left: 3px solid #{phase_color(week.phase)}"}
        >
          <div class="flex items-baseline justify-between px-4 pb-2 pt-3">
            <span class="flex items-baseline gap-2.5">
              <span class="display text-2xl" style={"color: #{phase_color(week.phase)}"}>
                S{week.index}
              </span>
              <span class="text-[11px] font-semibold uppercase tracking-[0.04em] text-dim">
                {week.label}
              </span>
            </span>
            <span class="num text-[11px] text-faint">
              {week_dates(week, @race, length(@plan.weeks))}
            </span>
          </div>
          <ul class="divide-y divide-line border-t border-line">
            <li :for={session <- week.sessions} class="flex items-baseline gap-3 px-4 py-2">
              <span class="w-24 shrink-0 text-xs font-medium text-text">{session.label}</span>
              <span class="num w-14 shrink-0 text-xs font-semibold text-signal">
                {Pace.format_duration(session.duration_s)}
              </span>
              <span class="min-w-0 text-[11px] leading-snug text-faint">{session.structure}</span>
            </li>
          </ul>
          <div class="num flex justify-between px-4 py-2 text-[11px] text-faint">
            <span>charge {round(week.target_load)}</span>
            <span>{Pace.format_duration(week.total_duration_s)}</span>
          </div>
        </article>
      </div>

      <p class="max-w-prose px-5 py-5 text-[11px] leading-relaxed text-faint">
        Ce plan est une trame deduite de ta charge actuelle, de ton rythme reel
        de seances et de tes allures. Il ne sait rien de ton sommeil a venir, de
        tes contraintes ni de tes antecedents : a adapter, pas a suivre a la
        lettre.
      </p>
    </section>
    """
  end

  # -- briques -----------------------------------------------------------------

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp field(assigns) do
    ~H"""
    <label class="flex flex-col gap-1.5">
      <span class="label">{@label}</span>
      {render_slot(@inner_block)}
    </label>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :note, :string, default: nil
  attr :tone, :string, default: "text"
  attr :small, :boolean, default: false

  defp stat(assigns) do
    ~H"""
    <div class="tile px-4 py-3.5">
      <div class="label">{@label}</div>
      <div class={[
        "mt-2",
        if(@small, do: "text-sm font-semibold leading-tight", else: "display text-[2rem]"),
        tone_class(@tone)
      ]}>
        {@value || "—"}
      </div>
      <div :if={@note} class="mt-1.5 text-[10px] text-faint">{@note}</div>
    </div>
    """
  end

  defp input_class,
    do: "num field"

  defp tone_class("signal"), do: "text-signal"
  defp tone_class("form"), do: "text-form"
  defp tone_class("alert"), do: "text-alert"
  defp tone_class("fatigue"), do: "text-fatigue"
  defp tone_class(_other), do: "text-text"

  defp verdict_tone(:reached), do: "form"
  defp verdict_tone(:reachable), do: "form"
  defp verdict_tone(:tight), do: "fatigue"
  defp verdict_tone(:out_of_reach), do: "alert"
  defp verdict_tone(_unknown), do: "text"

  defp verdict_bar(:out_of_reach), do: "border-t-alert"
  defp verdict_bar(:tight), do: "border-t-fatigue"
  defp verdict_bar(_other), do: "border-t-form"

  defp projected(%{current_cs: cs, weekly_gain: gain, weeks_available: weeks})
       when is_number(cs),
       do: cs + cs * gain * weeks

  defp projected(_assessment), do: nil

  defp number(nil, _precision), do: "—"
  defp number(value, precision), do: value |> Float.round(precision) |> to_string()

  # La derniere semaine du plan se termine le jour de la course ; on remonte
  # de la pour dater chaque semaine. Compter en avant depuis aujourd'hui
  # ferait deriver la fin du plan d'un a six jours selon le jour de la
  # semaine ou on le genere.
  defp week_start(week, race, total_weeks) do
    Date.add(race.date, -7 * (total_weeks - week.index + 1) + 1)
  end

  defp week_dates(week, race, total_weeks) do
    start = week_start(week, race, total_weeks)
    finish = Date.add(start, 6)
    "#{start.day}/#{start.month} – #{finish.day}/#{finish.month}"
  end

  defp distances, do: @distances

  defp load_bars(weeks) do
    Enum.map(weeks, fn week ->
      %{
        value: week.target_load,
        label: "S#{week.index}",
        color: phase_color(week.phase),
        title: "S#{week.index} · #{week.label} · charge #{round(week.target_load)}"
      }
    end)
  end

  defp phase_color(:base), do: "var(--color-form)"
  defp phase_color(:build), do: "var(--color-accent)"
  defp phase_color(:peak), do: "var(--color-signal)"
  defp phase_color(:taper), do: "var(--color-fatigue)"
  defp phase_color(_phase), do: "var(--color-dim)"
end
