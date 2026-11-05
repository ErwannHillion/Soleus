defmodule SoleusWeb.DashboardLive do
  @moduledoc """
  Le tableau de bord.

  Tout est charge en une passe dans `mount/3` via `Soleus.Analytics.dashboard/1`
  : la page est un instrument de lecture, pas une application interactive, et
  la recharger entierement coute moins cher qu'entretenir un etat partiel.
  """

  use SoleusWeb, :live_view

  import SoleusWeb.Charts

  alias Soleus.Analytics
  alias Soleus.Analytics.{Decoupling, Load, Pace}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, Analytics.dashboard("run"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-ink">
      <header class="flex items-baseline justify-between border-b border-line px-6 py-4">
        <div class="flex items-baseline gap-3">
          <span class="h-2.5 w-2.5 translate-y-[-1px] bg-signal"></span>
          <h1 class="text-sm font-semibold tracking-[0.32em] text-text">SOLEUS</h1>
          <span class="label">course a pied</span>
        </div>

        <div class="flex items-baseline gap-6">
          <.week_stat label="cette semaine" week={@weeks.current} />
          <.week_stat label="precedente" week={@weeks.previous} muted />
          <span class="num text-[11px] text-faint">{format_date(@today)}</span>
        </div>
      </header>

      <main class="divide-y divide-line">
        <.form_row form={@form} days={@load_days} />
        <.load_row days={@load_days} />

        <div class="grid grid-cols-1 divide-y divide-line lg:grid-cols-12 lg:divide-x lg:divide-y-0">
          <section class="lg:col-span-4">
            <.model_panel fit={@fit} paces={@paces} />
          </section>
          <section class="lg:col-span-4">
            <.predictions_panel fit={@fit} />
          </section>
          <section class="lg:col-span-4">
            <.goals_panel goals={@goals} />
          </section>
        </div>

        <div class="grid grid-cols-1 divide-y divide-line lg:grid-cols-12 lg:divide-x lg:divide-y-0">
          <section class="lg:col-span-7">
            <.panel_head
              title="Courbe vitesse-duree"
              note={"fenetre #{Analytics.fit_window_days()} jours"}
            />
            <div class="px-5 pb-5">
              <.curve_chart efforts={@curve} cs={@cs} class="h-56 w-full" />
              <p class="mt-3 text-[11px] leading-relaxed text-faint">
                Chaque point est le meilleur effort tenu sur cette duree. Le trait
                est le modele de vitesse critique : plein ou il est valide,
                pointille au dela.
              </p>
            </div>
          </section>
          <section class="lg:col-span-5">
            <.panel_head title="Progression de la vitesse critique" note="12 mois" />
            <div class="px-5 pb-5">
              <.progression_chart fits={@fits} class="h-40 w-full" />
              <p class="mt-3 text-[11px] leading-relaxed text-faint">
                La pente de cette courbe est ce que la projection extrapole.
              </p>
            </div>
          </section>
        </div>

        <div class="grid grid-cols-1 divide-y divide-line lg:grid-cols-12 lg:divide-x lg:divide-y-0">
          <section class="lg:col-span-5">
            <.bests_panel bests={@bests} />
          </section>
          <section class="lg:col-span-7">
            <.recent_panel activities={@recent} />
          </section>
        </div>
      </main>
    </div>
    """
  end

  # -- bandeau de forme -------------------------------------------------------

  attr :form, :any, required: true
  attr :days, :list, required: true

  defp form_row(assigns) do
    {state, verdict} = Load.interpret(assigns.form && assigns.form.tsb)

    assigns = assign(assigns, state: state, verdict: verdict)

    ~H"""
    <div class="grid grid-cols-2 divide-x divide-line md:grid-cols-4">
      <.stat
        label="charge chronique"
        value={number(@form && @form.ctl, 1)}
        note={"condition · #{Load.ctl_days()} jours"}
        tone="signal"
        signal
      />
      <.stat
        label="charge aigue"
        value={number(@form && @form.atl, 1)}
        note={"fatigue · #{Load.atl_days()} jours"}
        tone="fatigue"
      />
      <.stat
        label="forme"
        value={signed(@form && @form.tsb, 1)}
        note={@verdict}
        tone={if @state in [:overreaching], do: "alert", else: "form"}
      />
      <.stat
        label="montee en charge"
        value={signed(@form && @form.ramp_rate, 1)}
        note="variation hebdomadaire"
        tone={ramp_tone(@form && @form.ramp_rate)}
      />
    </div>
    """
  end

  attr :days, :list, required: true

  defp load_row(assigns) do
    ~H"""
    <section>
      <.panel_head title="Charge et forme" note="180 jours" />
      <div class="px-5 pb-5">
        <.load_chart days={@days} class="h-48 w-full" />
        <.form_strip days={@days} class="mt-1 h-14 w-full" />

        <div class="mt-3 flex flex-wrap items-center gap-x-5 gap-y-1">
          <.legend color="var(--color-signal)" label="charge chronique" />
          <.legend color="var(--color-fatigue)" label="charge aigue" />
          <.legend color="var(--color-signal)" label="charge du jour" faded />
          <.legend color="var(--color-form)" label="forme positive" />
          <.legend color="var(--color-alert)" label="forme negative" />
        </div>
      </div>
    </section>
    """
  end

  # -- panneaux ---------------------------------------------------------------

  attr :fit, :any, required: true
  attr :paces, :any, default: nil

  defp model_panel(assigns) do
    ~H"""
    <.panel_head title="Modele" note={@fit && format_date(@fit.fitted_on)} />

    <div :if={@fit && @fit.cs_ms} class="px-5 pb-5">
      <div class="flex items-baseline gap-2">
        <span class="num text-4xl text-signal">{Pace.format(@fit.cs_ms)}</span>
        <span class="text-xs text-dim">/ km</span>
      </div>
      <div class="label mt-1">vitesse critique · {number(@fit.cs_ms, 3)} m/s</div>

      <dl class="mt-5 grid grid-cols-2 gap-x-4 gap-y-3">
        <.metric label="reserve D'" value={"#{number(@fit.d_prime_m, 0)} m"} />
        <.metric label="VDOT" value={number(@fit.vdot, 1)} />
        <.metric label="exposant d'endurance" value={number(@fit.endurance_exponent, 3)}>
          <span class={["chip ml-1", @fit.exponent_source == "personal" && "chip-signal"]}>
            {if @fit.exponent_source == "personal", do: "personnel", else: "litterature"}
          </span>
        </.metric>
        <.metric label="qualite de l'ajustement" value={"R2 #{number(@fit.r2, 3)}"} />
      </dl>

      <div :if={@paces} class="mt-5 border-t border-line pt-4">
        <div class="label mb-2">allures d'entrainement</div>
        <div class="grid grid-cols-2 gap-x-4 gap-y-1.5">
          <div :for={{zone, label} <- pace_zones()} class="flex items-baseline justify-between">
            <span class="text-[11px] text-dim">{label}</span>
            <span class="num text-xs text-text">{Pace.format(@paces[zone])}</span>
          </div>
        </div>
      </div>
    </div>

    <p :if={is_nil(@fit) || is_nil(@fit.cs_ms)} class="px-5 pb-5 text-xs text-faint">
      Pas encore assez d'efforts records entre deux et vingt minutes pour ajuster
      le modele.
    </p>
    """
  end

  attr :fit, :any, required: true

  defp predictions_panel(assigns) do
    ~H"""
    <.panel_head
      title="Predictions"
      note={@fit && @fit.exponent_source == "literature" && "exposant moyen"}
    />

    <table :if={@fit && map_size(@fit.predictions) > 0} class="w-full">
      <tbody class="divide-y divide-line">
        <tr :for={{distance, time} <- sorted_predictions(@fit)} class="row-hover">
          <td class="py-2.5 pl-5 text-xs text-dim">{Pace.distance_label(distance)}</td>
          <td class="num py-2.5 text-right text-sm text-text">{Pace.format_duration(time)}</td>
          <td class="num py-2.5 pr-5 text-right text-[11px] text-faint">
            {Pace.format(distance / time)} /km
          </td>
        </tr>
      </tbody>
    </table>

    <p :if={is_nil(@fit) || map_size(@fit.predictions) == 0} class="px-5 pb-5 text-xs text-faint">
      Aucune prediction disponible.
    </p>
    """
  end

  attr :goals, :list, required: true

  defp goals_panel(assigns) do
    ~H"""
    <.panel_head title="Objectifs projetes" note="prochain palier rond" />

    <ul :if={@goals != []} class="divide-y divide-line">
      <li :for={goal <- @goals} class="row-hover flex items-baseline justify-between px-5 py-2.5">
        <span class="text-xs text-dim">
          {Pace.distance_label(goal.distance_m)}
          <span class="text-faint">sous</span>
          <span class="num text-text">{Pace.format_duration(goal.goal_time_s)}</span>
        </span>
        <.goal_outcome result={goal.result} />
      </li>
    </ul>

    <p :if={@goals == []} class="px-5 pb-5 text-xs text-faint">
      Les objectifs apparaissent des que les modeles sont ajustes.
    </p>
    """
  end

  attr :result, :any, required: true

  defp goal_outcome(%{result: {:ok, %{status: :already_reached}}} = assigns) do
    ~H"""
    <span class="chip chip-signal">atteint</span>
    """
  end

  defp goal_outcome(%{result: {:ok, projection}} = assigns) do
    assigns = assign(assigns, :projection, projection)

    ~H"""
    <span class="flex items-baseline gap-2">
      <span class="num text-xs text-text">{format_date(@projection.date)}</span>
      <span class="num text-[10px] text-faint">{@projection.days} j</span>
    </span>
    """
  end

  defp goal_outcome(%{result: {:error, reason}} = assigns) do
    assigns = assign(assigns, :reason, reason)

    ~H"""
    <span class="text-[10px] text-faint">{short_error(@reason)}</span>
    """
  end

  attr :bests, :list, required: true

  defp bests_panel(assigns) do
    ~H"""
    <.panel_head title="Records" note="toutes periodes" />

    <table :if={@bests != []} class="w-full">
      <tbody class="divide-y divide-line">
        <tr :for={best <- @bests} class="row-hover">
          <td class="py-2.5 pl-5 text-xs text-dim">{Pace.distance_label(best.distance_m)}</td>
          <td class="num py-2.5 text-right text-sm text-text">
            {Pace.format_duration(best.duration_s)}
          </td>
          <td class="num py-2.5 text-right text-[11px] text-faint">
            {Pace.format(best.speed_ms)} /km
          </td>
          <td class="num py-2.5 pr-5 text-right text-[11px] text-faint">
            {format_date(DateTime.to_date(best.started_at))}
          </td>
        </tr>
      </tbody>
    </table>

    <p :if={@bests == []} class="px-5 pb-5 text-xs text-faint">Aucun record enregistre.</p>
    """
  end

  attr :activities, :list, required: true

  defp recent_panel(assigns) do
    ~H"""
    <.panel_head title="Dernieres seances" note={"#{length(@activities)} affichees"} />

    <table class="w-full">
      <thead>
        <tr class="border-b border-line">
          <th class="label py-1.5 pl-5 text-left font-medium">date</th>
          <th class="label py-1.5 text-left font-medium">seance</th>
          <th class="label py-1.5 text-right font-medium">dist.</th>
          <th class="label py-1.5 text-right font-medium">allure</th>
          <th class="label py-1.5 text-right font-medium">FC</th>
          <th class="label py-1.5 text-right font-medium">charge</th>
          <th class="label py-1.5 pr-5 text-right font-medium">derive</th>
        </tr>
      </thead>
      <tbody class="divide-y divide-line">
        <tr :for={activity <- @activities} class="row-hover">
          <td class="num py-2 pl-5 text-[11px] text-faint">
            {format_date(activity.local_date)}
          </td>
          <td class="max-w-[12rem] truncate py-2 text-xs text-dim">{activity.name || "—"}</td>
          <td class="num py-2 text-right text-xs text-text">
            {number((activity.distance_m || 0) / 1000, 1)}
          </td>
          <td class="num py-2 text-right text-xs text-text">
            {Pace.format(activity.avg_speed_ms)}
          </td>
          <td class="num py-2 text-right text-xs text-dim">{activity.avg_hr || "—"}</td>
          <td class="num py-2 text-right text-xs text-signal">{number(activity.load, 0)}</td>
          <td class="num py-2 pr-5 text-right text-xs" style={decoupling_style(activity.decoupling)}>
            {decoupling_label(activity.decoupling)}
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  # -- briques --------------------------------------------------------------

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
  attr :note, :string, default: nil
  attr :tone, :string, default: "text"
  attr :signal, :boolean, default: false

  defp stat(assigns) do
    ~H"""
    <div class={["px-5 py-5", @signal && "panel-signal"]}>
      <div class="label">{@label}</div>
      <div class={["num mt-1.5 text-3xl leading-none", tone_class(@tone)]}>{@value}</div>
      <div :if={@note} class="mt-1.5 text-[11px] text-faint">{@note}</div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  slot :inner_block

  defp metric(assigns) do
    ~H"""
    <div>
      <dt class="label">{@label}</dt>
      <dd class="num mt-0.5 flex items-baseline text-sm text-text">
        {@value}{render_slot(@inner_block)}
      </dd>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :week, :map, required: true
  attr :muted, :boolean, default: false

  defp week_stat(assigns) do
    ~H"""
    <div class="text-right">
      <div class="label">{@label}</div>
      <div class={["num text-sm", if(@muted, do: "text-faint", else: "text-text")]}>
        {number(@week.distance_m / 1000, 1)} km <span class="text-faint">·</span>
        {Pace.format_duration(@week.moving_time_s)}
      </div>
    </div>
    """
  end

  attr :color, :string, required: true
  attr :label, :string, required: true
  attr :faded, :boolean, default: false

  defp legend(assigns) do
    ~H"""
    <span class="flex items-center gap-1.5">
      <span
        class="h-0.5 w-4"
        style={"background-color: #{@color}; opacity: #{if @faded, do: "0.25", else: "1"}"}
      ></span>
      <span class="text-[10px] text-faint">{@label}</span>
    </span>
    """
  end

  # -- mise en forme ----------------------------------------------------------

  defp tone_class("signal"), do: "text-signal"
  defp tone_class("fatigue"), do: "text-fatigue"
  defp tone_class("form"), do: "text-form"
  defp tone_class("alert"), do: "text-alert"
  defp tone_class(_tone), do: "text-text"

  # Une montee en charge au dela de cinq points par semaine est le seuil au dela
  # duquel la litterature sur la blessure devient nettement moins amicale.
  defp ramp_tone(rate) when is_number(rate) and rate > 5, do: "alert"
  defp ramp_tone(rate) when is_number(rate) and rate > 0, do: "form"
  defp ramp_tone(_rate), do: "text"

  defp number(nil, _precision), do: "—"

  defp number(value, 0) when is_number(value), do: value |> round() |> Integer.to_string()

  defp number(value, precision) when is_number(value) do
    value
    |> :erlang.float()
    |> Float.round(precision)
    |> :erlang.float_to_binary(decimals: precision)
  end

  defp signed(nil, _precision), do: "—"

  defp signed(value, precision) when is_number(value) do
    if value >= 0, do: "+" <> number(value, precision), else: number(value, precision)
  end

  @months ~w(janv. fevr. mars avr. mai juin juil. aout sept. oct. nov. dec.)

  defp format_date(nil), do: "—"

  defp format_date(%Date{} = date) do
    "#{date.day} #{Enum.at(@months, date.month - 1)}"
  end

  defp sorted_predictions(%{predictions: predictions}) do
    predictions
    |> Enum.map(fn {distance, time} -> {String.to_integer(distance) * 1.0, time} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp pace_zones do
    [
      {:easy, "facile"},
      {:marathon, "marathon"},
      {:threshold, "seuil"},
      {:interval, "intervalle"},
      {:repetition, "repetition"}
    ]
  end

  defp decoupling_label(nil), do: "—"
  defp decoupling_label(pct), do: signed(pct, 1) <> " %"

  # La couleur suit l'interpretation du decouplage, pas sa valeur brute : c'est
  # le franchissement du seuil de 5 % qui compte, pas la progression continue.
  defp decoupling_style(nil), do: "color: var(--color-faint)"

  defp decoupling_style(pct) do
    case Decoupling.interpret(pct) do
      {:decoupled, _} -> "color: var(--color-alert)"
      {:drifting, _} -> "color: var(--color-fatigue)"
      _ -> "color: var(--color-dim)"
    end
  end

  defp short_error(:beyond_horizon), do: "> 6 mois"
  defp short_error(:no_progression), do: "sans tendance"
  defp short_error(:not_enough_history), do: "historique court"
  defp short_error(_reason), do: "indisponible"
end
