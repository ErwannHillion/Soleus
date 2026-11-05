defmodule SoleusWeb.DashboardLive do
  @moduledoc """
  Le tableau de bord.

  Tout est charge en une passe dans `mount/3` via `Soleus.Analytics.dashboard/1`
  : la page est un instrument de lecture, pas une application interactive, et
  la recharger entierement coute moins cher qu'entretenir un etat partiel.
  """

  use SoleusWeb, :live_view

  import SoleusWeb.Charts
  import SoleusWeb.BodyFigure
  import SoleusWeb.Dock

  alias Phoenix.LiveView.JS
  alias Soleus.Analytics
  alias Soleus.Analytics.{Decoupling, Load, Pace}
  alias Soleus.Health
  alias Soleus.Ingest.Garmin.Token
  alias Soleus.Sync
  alias Soleus.Training

  # Les periodes proposees, en jours. « Tout » vaut `nil` : la borne est alors
  # la premiere donnee connue, qui n'est pas la meme pour les seances et pour
  # les mesures de sante.
  @periods [{"30 j", 30}, {"90 j", 90}, {"6 mois", 182}, {"1 an", 365}, {"Tout", nil}]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Sync.subscribe()

    {:ok,
     socket
     |> assign(period: 180, sport_filter: "run", selection: nil)
     |> assign(compare: default_compare())
     |> assign(sync: initial_sync_state())
     |> load_data()}
  end

  # L'etat initial est lu dans l'historique d'Oban : si une synchronisation
  # est deja en cours — celle du demarrage, par exemple — le bouton doit le
  # montrer des l'ouverture de la page plutot qu'apres le premier evenement.
  defp initial_sync_state do
    last = Sync.last_sync()

    cond do
      Sync.running?() -> %{state: :running, label: "en cours"}
      last && last.state == "completed" -> %{state: :idle, label: sync_age(last)}
      last && last.state == "discarded" -> %{state: :failed, label: "cle a verifier"}
      true -> %{state: :idle, label: "jamais"}
    end
  end

  # Le Pruner d'Oban efface les jobs apres une semaine : l'absence de
  # resultat ne veut donc pas dire « jamais », mais « rien depuis au moins
  # sept jours ».
  defp sync_age(%{completed_at: nil}), do: "date inconnue"

  defp sync_age(%{completed_at: at}) do
    case DateTime.diff(DateTime.utc_now(), DateTime.from_naive!(at, "Etc/UTC"), :minute) do
      minutes when minutes < 2 -> "a l'instant"
      minutes when minutes < 60 -> "il y a #{minutes} min"
      minutes when minutes < 1440 -> "il y a #{div(minutes, 60)} h"
      minutes -> "il y a #{div(minutes, 1440)} j"
    end
  end

  # -- synchronisation Garmin --------------------------------------------------

  @impl true
  def handle_info({:sync, :started, _info}, socket) do
    {:noreply, assign(socket, sync: %{state: :running, label: "connexion..."})}
  end

  def handle_info({:sync, :found, %{total: total}}, socket) do
    {:noreply, assign(socket, sync: %{state: :running, label: "#{total} activites a verifier"})}
  end

  def handle_info({:sync, :progress, %{index: index, total: total}}, socket) do
    {:noreply, assign(socket, sync: %{state: :running, label: "#{index} / #{total}"})}
  end

  # Les donnees ont change : on recharge la page plutot que de patcher des
  # assigns un par un. Une seance importee touche la charge, les modeles, les
  # records et la liste — enumerer ce qui bouge serait une liste a tenir a
  # jour a chaque nouvelle metrique.
  def handle_info({:sync, :done, %{imported: imported}}, socket) do
    label = if imported > 0, do: "#{imported} nouvelle(s)", else: "deja a jour"

    {:noreply,
     socket
     |> assign(sync: %{state: :done, label: label})
     |> load_data()}
  end

  def handle_info({:sync, :failed, %{reason: reason}}, socket) do
    {:noreply, assign(socket, sync: %{state: :failed, label: Token.explain(reason)})}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("set_period", %{"days" => raw}, socket) do
    {:noreply,
     socket
     |> assign(period: parse_period(raw), selection: nil)
     |> load_data()}
  end

  # Zone tracee au curseur sur le graphique de charge. Elle prend le pas sur
  # la periode choisie aux boutons, jusqu'a ce qu'on en rechoisisse une.
  def handle_event("select_range", %{"from" => from, "to" => to}, socket) do
    with {:ok, from} <- Date.from_iso8601(from),
         {:ok, to} <- Date.from_iso8601(to),
         # Moins de sept jours, le graphe de charge n'a plus rien a montrer :
         # la charge chronique est une moyenne sur six semaines.
         true <- Date.diff(to, from) >= 7 do
      {:noreply, socket |> assign(selection: {from, to}) |> load_data()}
    else
      _too_small -> {:noreply, socket}
    end
  end

  def handle_event("sync", _params, socket) do
    case Sync.trigger() do
      {:ok, _job} ->
        {:noreply, assign(socket, sync: %{state: :running, label: "demarrage..."})}

      {:error, reason} ->
        {:noreply, assign(socket, sync: %{state: :failed, label: Token.explain(reason)})}
    end
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, socket |> assign(selection: nil) |> load_data()}
  end

  def handle_event("set_compare", params, socket) do
    compare =
      Enum.reduce(~w(a_from a_to b_from b_to)a, socket.assigns.compare, fn key, acc ->
        case Date.from_iso8601(params[Atom.to_string(key)] || "") do
          {:ok, date} -> Map.put(acc, key, date)
          _invalid -> acc
        end
      end)

    {:noreply, socket |> assign(compare: compare) |> load_compare()}
  end

  def handle_event("set_sport", %{"sport" => raw}, socket) do
    sport = if raw in ["", "all"], do: nil, else: raw
    {:noreply, socket |> assign(sport_filter: sport) |> load_data()}
  end

  defp parse_period("all"), do: nil

  defp parse_period(raw) do
    case Integer.parse(raw) do
      {days, ""} when days > 0 -> days
      _invalid -> 180
    end
  end

  # Par defaut, le mois en cours contre le precedent : c'est la comparaison
  # qu'on fait spontanement, et elle donne un point de depart a ajuster plutot
  # qu'un formulaire vide.
  defp default_compare do
    today = Date.utc_today()

    %{
      a_from: Date.add(today, -30),
      a_to: today,
      b_from: Date.add(today, -60),
      b_to: Date.add(today, -31)
    }
  end

  defp load_compare(socket) do
    %{a_from: a_from, a_to: a_to, b_from: b_from, b_to: b_to} = socket.assigns.compare

    assign(socket,
      compare_a: period_summary(a_from, a_to),
      compare_b: period_summary(b_from, b_to)
    )
  end

  defp period_summary(from, to) do
    %{
      from: from,
      to: to,
      training: Analytics.training_totals(from, to),
      health: Health.averages(from, to)
    }
  end

  # Une seule fonction de chargement, appelee au montage et apres chaque
  # changement de filtre. La page est un instrument de lecture : recharger
  # l'ensemble coute moins cher a maintenir qu'un etat partiel a invalider.
  defp load_data(socket) do
    sport = socket.assigns.sport_filter || "run"
    today = Date.utc_today()

    {since, until} =
      case socket.assigns.selection do
        {from, to} -> {from, to}
        nil -> {Date.add(today, -(socket.assigns.period || 3650)), today}
      end

    days = max(Date.diff(until, since), 1)

    socket
    |> assign(Analytics.dashboard(sport, days: Date.diff(today, since)))
    |> assign(:sport_filter, socket.assigns.sport_filter)
    |> assign(:period, socket.assigns.period)
    |> assign(:since, since)
    |> assign(:until, until)
    |> then(&assign(&1, :load_days, clamp_days(&1.assigns.load_days, since, until)))
    |> assign(:wellness, Health.range(since, until))
    |> then(fn socket ->
      mine = Analytics.load_points(since, until)
      theirs = Health.series(:garmin_chronic_load, since, until)

      socket
      |> assign(:my_load, mine)
      |> assign(:garmin_load, theirs)
      |> assign(:load_correlation, Analytics.correlation(mine, theirs))
    end)
    |> load_compare()
    |> assign(:health_snapshot, Health.snapshot())
    |> assign(:today_health, Health.latest())
    |> assign(:health_averages, Health.averages(since, until))
    |> assign(:previous_averages, Health.averages(Date.add(since, -days), since))
    |> assign(
      :sessions,
      Training.list_activities(sport: socket.assigns.sport_filter, since: since, limit: 200)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- `h-dvh` et non `h-screen` : sur Safari iOS, `100vh` inclut la barre
          d'adresse et la derniere rangee de panneaux passe sous l'ecran. --%>
    <div class="flex h-dvh flex-col overflow-hidden bg-ink">
      <header class="flex shrink-0 items-baseline justify-between border-b border-line px-5 py-3">
        <div class="flex items-baseline gap-3">
          <span class="h-2.5 w-2.5 translate-y-[-1px] bg-signal"></span>
          <h1 class="text-sm font-semibold tracking-[0.32em] text-text">SOLEUS</h1>
          <span class="label">{view_label(@live_action)}</span>
        </div>

        <div class="flex items-center gap-5">
          <.week_stat label="cette semaine" week={@weeks.current} />
          <.week_stat label="precedente" week={@weeks.previous} muted />
          <.sync_button sync={@sync} />
          <.period_picker current={@period} />
          <span class="num text-[11px] text-faint">{format_date(@today)}</span>
        </div>
      </header>

      <%!-- Le rembourrage bas laisse passer le dock : il flotte au dessus du
            contenu, donc sans cette marge la derniere ligne reste sous lui. --%>
      <main class="flex-1 overflow-y-auto pb-28">
        <.view_home :if={@live_action == :home} {assigns} />
        <.view_form :if={@live_action == :form} {assigns} />
        <.view_sessions :if={@live_action == :sessions} {assigns} />
        <.view_curve :if={@live_action == :curve} {assigns} />
        <.view_body :if={@live_action == :body} {assigns} />
        <.view_compare :if={@live_action == :compare} {assigns} />
        <.view_predictions :if={@live_action == :predictions} {assigns} />
      </main>

      <.dock current={@live_action} />
    </div>
    """
  end

  # -- vues -------------------------------------------------------------------

  # -- vue d'ensemble ----------------------------------------------------------

  # L'accueil ne presente aucune donnee qui lui soit propre : il reprend, en
  # plus serre, ce que chaque page detaille. Le decoupage suit les trois
  # questions qu'on se pose en ouvrant l'application — suis-je en forme, ou
  # j'en suis, et qu'est-ce que j'ai fait recemment.
  defp view_home(assigns) do
    {snapshot, as_of} =
      case assigns.health_snapshot do
        {snapshot, as_of} -> {snapshot, as_of}
        nil -> {nil, nil}
      end

    assigns =
      assigns
      |> assign(:systems, Health.systems(snapshot))
      |> assign(:as_of, as_of)

    ~H"""
    <div class="flex min-h-full flex-col divide-y divide-line">
      <.form_row form={@form} days={@load_days} />

      <div class="grid grid-cols-1 divide-y divide-line xl:grid-cols-12 xl:divide-x xl:divide-y-0">
        <section class="xl:col-span-8">
          <.panel_head title="Charge et forme" note={range_note(@since, @until, @selection)} />
          <div class="px-5 pb-5">
            <.load_chart id="home-load" days={@load_days} class="w-full" />
            <.form_strip days={@load_days} class="mt-1 w-full" />
          </div>
        </section>

        <section class="xl:col-span-4">
          <.panel_head title="Etat du jour" note={@as_of && format_date(@as_of)} />
          <div class="flex items-start gap-4 px-5 pb-5">
            <.body_figure systems={@systems} class="h-56 w-auto shrink-0" />
            <dl class="grid flex-1 grid-cols-1 gap-y-3">
              <.metric
                :for={system <- Enum.take(@systems, 5)}
                label={system.label}
                value={system.value}
              >
                <span
                  class="ml-2 h-1.5 w-1.5 shrink-0 self-center rounded-full"
                  style={"background-color: #{status_color(system.status)}"}
                ></span>
              </.metric>
            </dl>
          </div>
        </section>
      </div>

      <div class="grid grid-cols-1 divide-y divide-line xl:grid-cols-12 xl:divide-x xl:divide-y-0">
        <section class="xl:col-span-4">
          <.model_panel fit={@fit} paces={@paces} />
        </section>
        <section class="xl:col-span-4">
          <.predictions_panel fit={@fit} />
        </section>
        <section class="xl:col-span-4">
          <.goals_panel goals={@goals} />
        </section>
      </div>

      <div class="flex-1">
        <.recent_panel activities={Enum.take(@recent, 10)} title="Dernieres seances" />
      </div>
    </div>
    """
  end

  defp view_form(assigns) do
    ~H"""
    <div class="flex min-h-full flex-col divide-y divide-line">
      <.form_row form={@form} days={@load_days} />
      <.load_row days={@load_days} since={@since} until={@until} selection={@selection} />
      <.overlay_panel
        mine={@my_load}
        theirs={@garmin_load}
        correlation={@load_correlation}
      />
      <div class="flex-1">
        <.recent_panel activities={Enum.take(@recent, 8)} title="Dernieres seances" />
      </div>
    </div>
    """
  end

  defp view_sessions(assigns) do
    ~H"""
    <div class="min-h-full">
      <.sport_picker current={@sport_filter} sports={@sports} />
      <.recent_panel activities={@sessions} title="Seances" />
    </div>
    """
  end

  # -- vue Corps ---------------------------------------------------------------

  defp view_body(assigns) do
    {snapshot, as_of} =
      case assigns.health_snapshot do
        {snapshot, as_of} -> {snapshot, as_of}
        nil -> {nil, nil}
      end

    assigns =
      assigns
      |> assign(:systems, Health.systems(snapshot))
      |> assign(:snapshot, snapshot)
      |> assign(:as_of, as_of)

    ~H"""
    <div class="flex min-h-full flex-col divide-y divide-line">
      <div class="grid grid-cols-1 divide-y divide-line xl:grid-cols-12 xl:divide-x xl:divide-y-0">
        <section class="xl:col-span-4">
          <.panel_head
            title="Etat general"
            note={@as_of && format_date(@as_of)}
          />
          <div class="flex justify-center px-5 pb-6">
            <.body_figure systems={@systems} class="max-h-[58vh] w-auto" />
          </div>
          <p class="px-5 pb-5 text-[11px] leading-relaxed text-faint">
            Chaque region prend l'etat le plus degrade des mesures qui s'y
            rattachent. Les seuils viennent des lignes de base que Garmin etablit
            sur ton propre historique, pas de normes generales.
          </p>
        </section>

        <section class="xl:col-span-8">
          <.panel_head title="Systemes" note={"#{length(@systems)} mesures"} />
          <div class="grid grid-cols-1 gap-px border-t border-line bg-line sm:grid-cols-2 2xl:grid-cols-3">
            <.system_card :for={system <- @systems} system={system} />
          </div>

          <.comparison current={@health_averages} previous={@previous_averages} days={@period} />
        </section>
      </div>

      <div class="grid flex-1 grid-cols-1 divide-y divide-line xl:grid-cols-2 xl:divide-x xl:divide-y-0">
        <.wellness_panel
          id="chart-hrv"
          series_label="variabilite"
          unit=" ms"
          title="Variabilite cardiaque"
          note="nocturne, avec ta fourchette normale"
          points={wellness_points(@wellness, :hrv_overnight)}
          baseline={baseline(@snapshot, :hrv_baseline_low, :hrv_baseline_high)}
          color="var(--color-signal)"
        />
        <.wellness_panel
          id="chart-rhr"
          series_label="FC au repos"
          unit=" bpm"
          title="Frequence au repos"
          note="plus bas, mieux c'est"
          points={wellness_points(@wellness, :resting_hr)}
          baseline={baseline(@snapshot, :hr_baseline_low, :hr_baseline_high)}
          color="var(--color-alert)"
        />
        <.wellness_panel
          id="chart-stress"
          series_label="stress moyen"
          title="Stress"
          note="moyenne de la journee"
          points={wellness_points(@wellness, :stress_avg)}
          color="var(--color-alert)"
        />
        <.wellness_panel
          id="chart-battery"
          series_label="pic"
          title="Reserve d'energie"
          note="pic quotidien"
          points={wellness_points(@wellness, :body_battery_high)}
          color="var(--color-fatigue)"
        />
      </div>

      <.sleep_panel nights={@wellness} />
    </div>
    """
  end

  attr :nights, :list, required: true

  defp sleep_panel(assigns) do
    ~H"""
    <section class="border-t border-line">
      <.panel_head
        title="Phases de sommeil"
        note={"#{Enum.count(@nights, & &1.sleep_total_s)} nuits"}
      />
      <div class="px-5 pb-5">
        <.sleep_chart nights={@nights} class="w-full" />
        <div class="mt-3 flex flex-wrap items-center gap-x-5 gap-y-1">
          <.legend :for={{_field, label, color} <- sleep_phases()} color={color} label={label} />
        </div>
      </div>
    </section>
    """
  end

  attr :mine, :list, required: true
  attr :theirs, :list, required: true
  attr :correlation, :any, default: nil

  defp overlay_panel(assigns) do
    ~H"""
    <section>
      <.panel_head
        title="Charge chronique : Soleus contre Garmin"
        note={correlation_note(@correlation)}
      />
      <div class="px-5 pb-5">
        <.overlay_chart
          mine={@mine}
          theirs={@theirs}
          mine_label="Soleus (CTL)"
          theirs_label="Garmin (charge chronique)"
          class="w-full"
        />
        <div class="mt-3 flex flex-wrap items-center gap-x-5 gap-y-1">
          <.legend color="var(--color-signal)" label="Soleus" />
          <.legend color="var(--color-fatigue)" label="Garmin" />
        </div>
        <p class="mt-3 max-w-prose text-[11px] leading-relaxed text-faint">
          Les deux echelles sont incomparables par construction — un score
          rapporte a la vitesse critique contre un EPOC estime — donc chaque
          serie est ramenee a sa propre amplitude et l'axe n'est pas gradue.
          Ce qui se compare, c'est la forme.
        </p>
      </div>
    </section>
    """
  end

  defp correlation_note(nil), do: "pas assez de jours communs"

  defp correlation_note(r) do
    qualite =
      cond do
        r > 0.9 -> "tres proches"
        r > 0.7 -> "concordants"
        r > 0.4 -> "partiellement concordants"
        true -> "divergents"
      end

    "r = #{Float.round(r, 2)} · #{qualite}"
  end

  defp view_compare(assigns) do
    ~H"""
    <div class="min-h-full">
      <form
        phx-change="set_compare"
        class="flex flex-wrap items-end gap-6 border-b border-line px-5 py-4"
      >
        <.range_input legend="Periode A" prefix="a" from={@compare.a_from} to={@compare.a_to} accent />
        <.range_input legend="Periode B" prefix="b" from={@compare.b_from} to={@compare.b_to} />
      </form>

      <.panel_head
        title="Entrainement"
        note={"#{@compare_a.training.days} jours contre #{@compare_b.training.days}"}
      />
      <div class="grid grid-cols-2 gap-px border-y border-line bg-line sm:grid-cols-3 2xl:grid-cols-6">
        <.versus
          label="distance"
          a={@compare_a.training.distance_m}
          b={@compare_b.training.distance_m}
          format={:km}
        />
        <.versus
          label="temps"
          a={@compare_a.training.moving_time_s}
          b={@compare_b.training.moving_time_s}
          format={:duration}
        />
        <.versus
          label="seances"
          a={@compare_a.training.activity_count}
          b={@compare_b.training.activity_count}
        />
        <.versus
          label="charge cumulee"
          a={@compare_a.training.load}
          b={@compare_b.training.load}
          format={:count}
        />
        <.versus
          label="par semaine"
          a={per_week(@compare_a.training)}
          b={per_week(@compare_b.training)}
          format={:km}
        />
        <.versus
          label="charge chronique"
          a={@compare_a.training.ctl_end}
          b={@compare_b.training.ctl_end}
        />
      </div>

      <.panel_head title="Sante" note="moyennes sur la periode" />
      <div class="grid grid-cols-2 gap-px border-y border-line bg-line sm:grid-cols-3 2xl:grid-cols-6">
        <.versus
          label="sommeil"
          a={@compare_a.health[:sleep_total_s]}
          b={@compare_b.health[:sleep_total_s]}
          format={:duration}
        />
        <.versus
          label="score de sommeil"
          a={@compare_a.health[:sleep_score]}
          b={@compare_b.health[:sleep_score]}
        />
        <.versus
          label="variabilite"
          a={@compare_a.health[:hrv_overnight]}
          b={@compare_b.health[:hrv_overnight]}
          unit=" ms"
        />
        <.versus
          label="FC au repos"
          a={@compare_a.health[:resting_hr]}
          b={@compare_b.health[:resting_hr]}
          unit=" bpm"
          lower_is_better
        />
        <.versus
          label="stress"
          a={@compare_a.health[:stress_avg]}
          b={@compare_b.health[:stress_avg]}
          lower_is_better
        />
        <.versus
          label="etat de forme"
          a={@compare_a.health[:training_readiness]}
          b={@compare_b.health[:training_readiness]}
        />
      </div>

      <p class="max-w-prose px-5 py-5 text-[11px] leading-relaxed text-faint">
        Les deux periodes peuvent avoir des longueurs differentes. Les totaux
        cumules — distance, temps, charge — ne sont alors pas comparables tels
        quels ; la ligne « par semaine » l'est, elle.
      </p>
    </div>
    """
  end

  attr :legend, :string, required: true
  attr :prefix, :string, required: true
  attr :from, Date, required: true
  attr :to, Date, required: true
  attr :accent, :boolean, default: false

  defp range_input(assigns) do
    ~H"""
    <fieldset class="flex items-end gap-2">
      <legend class={["label mb-1.5", @accent && "text-signal"]}>{@legend}</legend>
      <input
        type="date"
        name={"#{@prefix}_from"}
        value={Date.to_iso8601(@from)}
        class="num border border-line bg-panel px-2 py-1 text-[11px] text-text"
      />
      <span class="pb-1 text-[10px] text-faint">au</span>
      <input
        type="date"
        name={"#{@prefix}_to"}
        value={Date.to_iso8601(@to)}
        class="num border border-line bg-panel px-2 py-1 text-[11px] text-text"
      />
    </fieldset>
    """
  end

  attr :label, :string, required: true
  attr :a, :any, default: nil
  attr :b, :any, default: nil
  attr :unit, :string, default: ""
  attr :format, :atom, default: :number
  attr :lower_is_better, :boolean, default: false

  # Les deux valeurs cote a cote, et leur ecart. L'ecart est colore selon le
  # sens du progres, qui depend de la mesure : gagner des battements au repos
  # est une mauvaise nouvelle, en gagner en variabilite une bonne.
  defp versus(assigns) do
    change = if is_number(assigns.a) and is_number(assigns.b), do: assigns.a - assigns.b

    improving? =
      is_number(change) and
        ((assigns.lower_is_better and change < 0) or (not assigns.lower_is_better and change > 0))

    assigns = assign(assigns, change: change, improving?: improving?)

    ~H"""
    <div class="bg-ink px-5 py-4">
      <div class="label">{@label}</div>
      <div class="num mt-1.5 text-xl leading-none text-signal">
        {measure(@a, @format, @unit)}
      </div>
      <div class="num mt-1 text-[11px] text-dim">{measure(@b, @format, @unit)}</div>
      <div
        :if={is_number(@change)}
        class="num mt-1.5 text-[11px]"
        style={"color: #{if @improving?, do: "var(--color-form)", else: "var(--color-fatigue)"}"}
      >
        {signed_measure(@change, @format, @unit)}
      </div>
    </div>
    """
  end

  defp per_week(%{distance_m: distance, weeks: weeks}) when weeks > 0, do: distance / weeks
  defp per_week(_totals), do: nil

  attr :system, :map, required: true

  defp system_card(assigns) do
    ~H"""
    <article class="row-hover bg-ink px-5 py-4">
      <div class="flex items-baseline justify-between">
        <span class="label">{@system.label}</span>
        <span class="flex items-center gap-1.5">
          <span
            class="h-1.5 w-1.5 rounded-full"
            style={"background-color: #{status_color(@system.status)}"}
          ></span>
          <span class="text-[10px] text-faint">{status_label(@system.status)}</span>
        </span>
      </div>
      <div class="num mt-1.5 text-2xl leading-none text-text">{@system.value}</div>
      <div class="mt-1.5 text-[11px] text-faint">{@system.detail}</div>
    </article>
    """
  end

  attr :title, :string, required: true
  attr :note, :string, default: nil
  attr :id, :string, required: true
  attr :points, :list, required: true
  attr :series_label, :string, required: true
  attr :unit, :string, default: ""
  attr :baseline, :any, default: nil
  attr :color, :string, default: "var(--color-signal)"

  defp wellness_panel(assigns) do
    ~H"""
    <section>
      <.panel_head title={@title} note={@note} />
      <div class="px-5 pb-5">
        <.daily_chart
          id={@id}
          points={@points}
          series_label={@series_label}
          unit={@unit}
          baseline={@baseline}
          color={@color}
          class="w-full"
        />
      </div>
    </section>
    """
  end

  attr :current, :map, required: true
  attr :previous, :map, required: true
  attr :days, :any, required: true

  # La comparaison a la periode precedente de meme longueur. C'est ce qui
  # transforme une moyenne en information : 7 h 12 de sommeil ne dit rien,
  # « 7 h 12, soit vingt minutes de moins que le mois d'avant » si.
  defp comparison(assigns) do
    ~H"""
    <div class="border-t border-line">
      <.panel_head
        title="Comparaison"
        note={"#{@days || "tout"} j contre la periode precedente"}
      />
      <dl class="grid grid-cols-2 gap-x-5 gap-y-4 px-5 pb-5 lg:grid-cols-4">
        <.delta
          label="sommeil"
          current={@current[:sleep_total_s]}
          previous={@previous[:sleep_total_s]}
          format={:duration}
        />
        <.delta
          label="variabilite cardiaque"
          current={@current[:hrv_overnight]}
          previous={@previous[:hrv_overnight]}
          unit=" ms"
        />
        <.delta
          label="FC au repos"
          current={@current[:resting_hr]}
          previous={@previous[:resting_hr]}
          unit=" bpm"
          lower_is_better
        />
        <.delta
          label="stress moyen"
          current={@current[:stress_avg]}
          previous={@previous[:stress_avg]}
          lower_is_better
        />
        <.delta
          label="score de sommeil"
          current={@current[:sleep_score]}
          previous={@previous[:sleep_score]}
        />
        <.delta
          label="reserve d'energie"
          current={@current[:body_battery_high]}
          previous={@previous[:body_battery_high]}
        />
        <.delta
          label="etat de forme"
          current={@current[:training_readiness]}
          previous={@previous[:training_readiness]}
        />
        <.delta label="pas par jour" current={@current[:steps]} previous={@previous[:steps]} />
      </dl>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :current, :any, default: nil
  attr :previous, :any, default: nil
  attr :unit, :string, default: ""
  attr :format, :atom, default: :number
  attr :lower_is_better, :boolean, default: false

  defp delta(assigns) do
    change =
      if is_number(assigns.current) and is_number(assigns.previous),
        do: assigns.current - assigns.previous

    improving? =
      is_number(change) and
        ((assigns.lower_is_better and change < 0) or (not assigns.lower_is_better and change > 0))

    assigns = assign(assigns, change: change, improving?: improving?)

    ~H"""
    <div>
      <dt class="label">{@label}</dt>
      <dd class="num mt-1 text-lg leading-none text-text">
        {measure(@current, @format, @unit)}
      </dd>
      <dd
        :if={is_number(@change)}
        class="num mt-1 text-[11px]"
        style={"color: #{if @improving?, do: "var(--color-form)", else: "var(--color-fatigue)"}"}
      >
        {signed_measure(@change, @format, @unit)}
      </dd>
      <dd :if={is_nil(@change)} class="mt-1 text-[11px] text-faint">pas de comparaison</dd>
    </div>
    """
  end

  attr :sync, :map, required: true

  defp sync_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="sync"
      disabled={@sync.state == :running}
      class={[
        "flex items-center gap-2 border px-2.5 py-1 transition-colors",
        "text-[10px] font-medium uppercase tracking-[0.08em]",
        @sync.state == :running && "cursor-wait border-line text-faint",
        @sync.state == :failed && "border-alert/50 text-alert",
        @sync.state == :done && "border-form/50 text-form",
        @sync.state == :idle && "border-line text-dim hover:border-line-bright hover:text-text"
      ]}
      title="Recuperer les nouvelles seances depuis Garmin"
    >
      <span class={[
        "h-3 w-3 bg-current",
        if(@sync.state == :running, do: "hero-arrow-path animate-spin", else: "hero-arrow-down-tray")
      ]} />
      <span>Garmin</span>
      <span class="num normal-case tracking-normal opacity-70">{@sync.label}</span>
    </button>
    """
  end

  attr :current, :any, required: true

  defp period_picker(assigns) do
    assigns = assign(assigns, :periods, @periods)

    ~H"""
    <div class="flex items-center gap-px border border-line">
      <button
        :for={{label, days} <- @periods}
        type="button"
        phx-click="set_period"
        phx-value-days={days || "all"}
        class={[
          "px-2.5 py-1 text-[10px] font-medium uppercase tracking-[0.08em] transition-colors",
          if(@current == days, do: "bg-signal-wash text-signal", else: "text-faint hover:text-text")
        ]}
      >
        {label}
      </button>
    </div>
    """
  end

  attr :current, :any, required: true
  attr :sports, :list, required: true

  defp sport_picker(assigns) do
    ~H"""
    <div class="flex items-center gap-px border-b border-line px-5 py-2.5">
      <button
        type="button"
        phx-click="set_sport"
        phx-value-sport="all"
        class={[
          "px-2.5 py-1 text-[10px] font-medium uppercase tracking-[0.08em] transition-colors",
          if(is_nil(@current), do: "bg-signal-wash text-signal", else: "text-faint hover:text-text")
        ]}
      >
        Tous
      </button>
      <button
        :for={{sport, count} <- @sports}
        type="button"
        phx-click="set_sport"
        phx-value-sport={sport}
        class={[
          "px-2.5 py-1 text-[10px] font-medium uppercase tracking-[0.08em] transition-colors",
          if(@current == sport, do: "bg-signal-wash text-signal", else: "text-faint hover:text-text")
        ]}
      >
        {sport_label(sport)} <span class="num opacity-60">{count}</span>
      </button>
    </div>
    """
  end

  defp view_curve(assigns) do
    ~H"""
    <div class="flex min-h-full flex-col divide-y divide-line">
      <div class="grid grid-cols-1 divide-y divide-line xl:grid-cols-12 xl:divide-x xl:divide-y-0">
        <section class="xl:col-span-7">
          <.panel_head
            title="Courbe vitesse-duree"
            note={"fenetre #{Analytics.fit_window_days()} jours"}
          />
          <div class="px-5 pb-5">
            <.curve_chart efforts={@curve} cs={@cs} class="w-full" />
            <p class="mt-3 max-w-prose text-[11px] leading-relaxed text-faint">
              Chaque point est le meilleur effort tenu sur cette duree. Le trait est
              le modele de vitesse critique : plein ou il est valide, pointille au
              dela.
            </p>
          </div>
        </section>

        <section class="xl:col-span-5">
          <.panel_head title="Progression de la vitesse critique" note="12 mois" />
          <div class="px-5 pb-5">
            <.progression_chart fits={@fits} class="w-full" />
            <p class="mt-3 max-w-prose text-[11px] leading-relaxed text-faint">
              La pente de cette courbe est ce que la projection extrapole. Les
              paliers sont normaux : la vitesse critique ne bouge que lorsqu'un
              effort record entre dans la fenetre glissante ou en sort.
            </p>
          </div>

          <.trend_panel goals={@goals} fits={@fits} />
        </section>
      </div>

      <div class="flex-1">
        <.bests_panel bests={@bests} />
      </div>
    </div>
    """
  end

  defp view_predictions(assigns) do
    ~H"""
    <div class="grid min-h-full grid-cols-1 divide-y divide-line xl:grid-cols-12 xl:divide-x xl:divide-y-0">
      <section class="xl:col-span-4">
        <.model_panel fit={@fit} paces={@paces} />
      </section>
      <section class="xl:col-span-4">
        <.predictions_panel fit={@fit} />
      </section>
      <section class="xl:col-span-4">
        <.goals_panel goals={@goals} />
      </section>
    </div>
    """
  end

  defp view_label(:home), do: "vue d'ensemble"
  defp view_label(:form), do: "forme"
  defp view_label(:sessions), do: "seances"
  defp view_label(:curve), do: "courbe vitesse-duree"
  defp view_label(:body), do: "corps"
  defp view_label(:compare), do: "comparaison"
  defp view_label(:predictions), do: "predictions"

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
  attr :since, Date, required: true
  attr :until, Date, required: true
  attr :selection, :any, default: nil

  defp load_row(assigns) do
    ~H"""
    <section>
      <.panel_head title="Charge et forme" note={range_note(@since, @until, @selection)} />
      <div class="px-5 pb-5">
        <%!-- Le glisser sur cette zone definit une plage de dates. Le hook ne
              fait que suivre le pointeur et convertir en dates ; tout le
              redessin reste cote serveur. --%>
        <div
          id="load-brush"
          phx-hook="Brush"
          data-from={Date.to_iso8601(@since)}
          data-to={Date.to_iso8601(@until)}
          class="relative cursor-crosshair select-none touch-none"
        >
          <div
            data-brush-overlay
            class="pointer-events-none absolute inset-y-0 hidden bg-signal/20 ring-1 ring-signal/50"
          >
          </div>
          <.load_chart days={@days} class="w-full" />
          <.form_strip days={@days} class="mt-1 w-full" />
        </div>

        <div class="mt-3 flex flex-wrap items-center gap-x-5 gap-y-1">
          <button
            :if={@selection}
            type="button"
            phx-click="clear_selection"
            class="chip chip-signal cursor-pointer"
          >
            zone selectionnee — effacer
          </button>
          <span :if={is_nil(@selection)} class="text-[10px] text-faint">
            glisser sur le graphique pour isoler une periode
          </span>
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
        <div class="grid grid-cols-1 gap-y-1.5">
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

  attr :goals, :list, required: true
  attr :fits, :list, required: true

  @doc false
  defp trend_panel(assigns) do
    # Les projections partagent toutes la meme tendance : le gain d'allure et la
    # fiabilite sont donc les memes sur chaque ligne, et n'ont a etre lus qu'une
    # fois. On prend donc la premiere projection aboutie.
    projection =
      assigns.goals
      |> Enum.find_value(fn
        %{result: {:ok, %{weekly_pace_gain_s: gain}} = result} when is_number(gain) -> result
        _other -> nil
      end)
      |> case do
        {:ok, projection} -> projection
        _other -> nil
      end

    assigns = assign(assigns, :projection, projection)

    ~H"""
    <div class="border-t border-line">
      <.panel_head title="Tendance" note={"#{length(@fits)} ajustements"} />

      <dl :if={@projection} class="grid grid-cols-2 gap-x-4 gap-y-4 px-5 pb-5">
        <.metric
          label="gain d'allure"
          value={"#{signed(@projection.weekly_pace_gain_s, 1)} s/km"}
        />
        <.metric label="par semaine" value={confidence_label(@projection.confidence)} />
        <.metric label="qualite de la tendance" value={"R2 #{number(@projection.r2, 3)}"} />
        <.metric label="points ajustes" value={number(@projection.sample_count, 0)} />
      </dl>

      <p :if={is_nil(@projection)} class="px-5 pb-5 text-xs text-faint">
        {Analytics.explain_error(:not_enough_history)}
      </p>
    </div>
    """
  end

  defp confidence_label(:high), do: "fiable"
  defp confidence_label(:medium), do: "indicative"
  defp confidence_label(_other), do: "fragile"

  attr :bests, :list, required: true

  defp bests_panel(assigns) do
    ~H"""
    <.panel_head title="Records" note="toutes periodes" />

    <div
      :if={@bests != []}
      class="grid grid-cols-2 gap-px border-t border-line bg-line sm:grid-cols-3 lg:grid-cols-5 2xl:grid-cols-8"
    >
      <article :for={best <- @bests} class="row-hover bg-ink px-4 py-3">
        <div class="label">{Pace.distance_label(best.distance_m)}</div>
        <div class="num mt-1 text-xl text-text">{Pace.format_duration(best.duration_s)}</div>
        <div class="num mt-0.5 text-[11px] text-faint">
          {Pace.format(best.speed_ms)} /km
          <span :if={best.avg_hr} class="text-dim">· {best.avg_hr} bpm</span>
        </div>
        <div class="num mt-1.5 text-[10px] text-faint">
          {format_date(DateTime.to_date(best.started_at))}
        </div>
      </article>
    </div>

    <p :if={@bests == []} class="px-5 pb-5 text-xs text-faint">Aucun record enregistre.</p>
    """
  end

  attr :activities, :list, required: true
  attr :title, :string, default: "Seances"

  defp recent_panel(assigns) do
    ~H"""
    <.panel_head title={@title} note={"#{length(@activities)} affichees"} />

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
        <tr
          :for={activity <- @activities}
          class="row-hover cursor-pointer"
          phx-click={JS.navigate(~p"/seance/#{activity.id}")}
        >
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

  # `Analytics.dashboard/2` ne sait que remonter depuis aujourd'hui. Une zone
  # qui se termine avant aujourd'hui doit donc etre recoupee ici, sinon le
  # graphe deborderait a droite de ce qui a ete selectionne.
  @months_short ~w(janv. fevr. mars avr. mai juin juil. aout sept. oct. nov. dec.)

  defp range_note(since, until, nil), do: "#{Date.diff(until, since)} jours"

  defp range_note(since, until, _selection) do
    "#{short_date(since)} → #{short_date(until)}"
  end

  defp short_date(date), do: "#{date.day} #{Enum.at(@months_short, date.month - 1)} #{date.year}"

  defp clamp_days(days, since, until) do
    Enum.filter(
      days,
      &(Date.compare(&1.date, since) != :lt and Date.compare(&1.date, until) != :gt)
    )
  end

  # -- extraction des mesures --------------------------------------------------

  # Les jours non mesures sont ecartes plutot que ramenes a zero : une nuit
  # sans la montre doit laisser un trou dans la courbe, pas une chute.
  defp wellness_points(days, field, transform \\ & &1) do
    days
    |> Enum.map(&{&1.date, Map.get(&1, field)})
    |> Enum.reject(fn {_date, value} -> is_nil(value) end)
    |> Enum.map(fn {date, value} -> {date, transform.(value)} end)
  end

  # La fourchette normale du jour le plus recent sert de reference a toute la
  # periode. Elle derive lentement, et afficher une bande par jour rendrait le
  # graphe illisible pour un gain nul.
  defp baseline(nil, _low_field, _high_field), do: nil

  defp baseline(day, low_field, high_field) do
    case {Map.get(day, low_field), Map.get(day, high_field)} do
      {low, high} when is_number(low) and is_number(high) -> {low, high}
      _missing -> nil
    end
  end

  defp measure(nil, _format, _unit), do: "—"
  defp measure(value, :km, _unit), do: number(value / 1000, 1) <> " km"
  defp measure(value, :count, _unit), do: number(value, 0)
  # Heures et minutes, et non `h:mm:ss` : les secondes d'une moyenne de
  # sommeil sur six mois n'apportent rien et encombrent la lecture.
  defp measure(value, :duration, _unit) do
    total = round(value)

    "#{div(total, 3600)} h #{total |> rem(3600) |> div(60) |> to_string() |> String.pad_leading(2, "0")}"
  end

  defp measure(value, _format, unit), do: number(value, 1) <> unit

  defp signed_measure(value, :duration, _unit) do
    total = abs(round(value))
    sign = if value >= 0, do: "+", else: "−"
    "#{sign}#{div(total, 60)} min"
  end

  defp signed_measure(value, :km, _unit), do: signed(value / 1000, 1) <> " km"
  defp signed_measure(value, :count, _unit), do: signed(value, 0)
  defp signed_measure(value, _format, unit), do: signed(value, 1) <> unit

  @sport_labels %{
    "run" => "Course",
    "ride" => "Velo",
    "swim" => "Natation",
    "walk" => "Marche",
    "hike" => "Rando",
    "strength" => "Renfo",
    "unknown" => "Autre"
  }

  defp sport_label(sport), do: Map.get(@sport_labels, sport, sport)

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
