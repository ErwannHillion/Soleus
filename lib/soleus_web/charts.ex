defmodule SoleusWeb.Charts do
  @moduledoc """
  Graphiques en SVG, generes cote serveur.

  Pas de bibliotheque JavaScript ici, et ce n'est pas un parti pris esthetique
  : les graphes du tableau de bord portent entre cent et trois cents points, ce
  qui tient largement en SVG inline. A cette taille, le rendu serveur evite un
  aller-retour, un etat client a synchroniser, et une dependance a maintenir.

  La limite est connue et assumee : au dela de quelques milliers de points —
  les series seconde par seconde d'une seance — le DOM devient le goulot et il
  faudra un `canvas` pilote par un hook. Ce module s'arrete avant cette
  frontiere.

  Tous les graphes dessinent dans un `viewBox` en coordonnees logiques, et
  imposent son rapport d'aspect en CSS plutot que d'autoriser l'etirement
  libre. La nuance compte : avec `preserveAspectRatio="none"`, un graphe de
  1000 x 200 affiche sur 1600 pixels de large etire tout d'un facteur 1,6
  horizontalement — les traits comme les libelles d'axe, qui deviennent baveux
  et trop larges. En fixant `aspect-ratio`, la hauteur suit la largeur et le
  texte reste a ses proportions.

  Les tailles de police sont donc exprimees dans le repere du `viewBox`, pas en
  pixels ecran : un graphe plus large est aussi plus haut, et son texte grandit
  proportionnellement.

  C'est pourquoi `width` est un attribut et non une constante. L'echelle de
  rendu vaut `largeur_reelle / width` : un graphe place dans une colonne de
  700 pixels mais dessine dans un `viewBox` de 1000 voit son texte reduit d'un
  tiers, et les libelles d'axe tombent sous six pixels. Caler `width` sur la
  largeur de rendu attendue garde les polices a leur taille nominale.
  """

  use Phoenix.Component

  alias Soleus.Analytics.CriticalSpeed
  alias Soleus.Analytics.Pace

  # -- cadre de survol ---------------------------------------------------------

  attr :id, :string, required: true
  attr :hover, :list, default: []
  attr :class, :string, default: nil
  slot :inner_block, required: true

  @doc """
  Enveloppe un graphique et lui donne la lecture au survol.

  Les points sont serialises une fois dans `data-hover` au rendu, et le hook
  resout le survol cote client. Un aller-retour LiveView par mouvement de
  souris afficherait, seize millisecondes plus tard, une valeur deja connue au
  moment du rendu.

  L'abscisse de chaque point est un **pourcentage** de la largeur et non des
  pixels : le SVG remplit son conteneur, donc le pourcentage reste juste a
  toutes les tailles d'ecran sans que le client ait a connaitre le `viewBox`.
  """
  def chart_frame(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="Hover"
      data-hover={Jason.encode!(@hover)}
      class={["relative", @class]}
    >
      <div
        data-hover-line
        class="pointer-events-none absolute inset-y-0 hidden w-px bg-line-bright"
      >
      </div>
      <div
        data-hover-card
        class="pointer-events-none absolute top-1 z-10 hidden min-w-[10rem] border border-line-bright bg-panel/95 px-2.5 py-2 shadow-lg backdrop-blur"
      >
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "Abscisse d'un point en pourcentage de la largeur du graphique."
  @spec percent(number(), number()) :: float()
  def percent(x, width), do: Float.round(x / width * 100, 3)

  # -- echelles ---------------------------------------------------------------

  @doc "Projette `value` du domaine `[d0, d1]` vers l'intervalle `[r0, r1]`."
  def scale(value, {d0, d1}, {r0, r1}) when d1 != d0 do
    r0 + (value - d0) / (d1 - d0) * (r1 - r0)
  end

  def scale(_value, _domain, {r0, _r1}), do: r0

  @doc """
  Echelle logarithmique, pour l'axe des durees.

  La courbe vitesse-duree se lit en log : les paliers interessants vont de cinq
  secondes a deux heures, et un axe lineaire ecraserait tout ce qui est en
  dessous de la minute contre l'origine.
  """
  def log_scale(value, {d0, d1}, range) when value > 0 and d0 > 0 do
    scale(:math.log(value), {:math.log(d0), :math.log(d1)}, range)
  end

  def log_scale(_value, _domain, {r0, _r1}), do: r0

  # -- charge et forme --------------------------------------------------------

  attr :days, :list, required: true, doc: "lignes de `Soleus.Analytics.DailyLoad` triees"
  attr :id, :string, default: "load-chart"
  attr :width, :integer, default: 1400
  attr :height, :integer, default: 350
  attr :class, :string, default: nil

  @doc """
  Charge chronique, charge aigue et charge quotidienne sur une meme grille.

  Les barres de charge quotidienne sont dessinees avant les courbes, et en
  violet tres dilue : ce sont les donnees brutes, les deux courbes en sont la
  lecture. L'inverse — des barres saturees derriere des traits fins — rendrait
  la tendance illisible, qui est pourtant la seule chose qu'on vient chercher.
  """
  def load_chart(assigns) do
    width = assigns.width
    pad_left = 42
    pad_right = 12
    pad_top = 14
    pad_bottom = 20

    days = assigns.days
    n = max(length(days), 1)

    y_max =
      days
      |> Enum.flat_map(&[&1.ctl, &1.atl, &1.load])
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> 100.0 end)
      |> then(&max(&1 * 1.12, 10.0))

    x_range = {pad_left, width - pad_right}
    y_range = {assigns.height - pad_bottom, pad_top}

    x = fn i -> scale(i, {0, max(n - 1, 1)}, x_range) end
    y = fn v -> scale(v || 0.0, {0.0, y_max}, y_range) end

    assigns =
      assigns
      |> assign(:bar_width, max((width - pad_left - pad_right) / n * 0.6, 0.7))
      |> assign(
        :bars,
        Enum.with_index(days) |> Enum.reject(fn {d, _} -> (d.load || 0.0) <= 0 end)
      )
      |> assign(:ctl_path, line_path(days, x, y, :ctl))
      |> assign(:atl_path, line_path(days, x, y, :atl))
      |> assign(:gridlines, for(f <- [0.25, 0.5, 0.75, 1.0], do: {f * y_max, y.(f * y_max)}))
      |> assign(:x_labels, month_ticks(days, x))
      |> assign(:x, x)
      |> assign(:y, y)
      |> assign(:baseline, y.(0.0))
      |> assign(:hover, load_hover(days, x, width))

    ~H"""
    <.chart_frame id={@id} hover={@hover} class={@class}>
      <svg
        viewBox={"0 0 #{@width} #{@height}"}
        style={aspect(@width, @height)}
        role="img"
      >
        <title>Charge chronique et charge aigue</title>

        <g>
          <line
            :for={{_value, py} <- @gridlines}
            x1="42"
            x2={@width - 12}
            y1={py}
            y2={py}
            stroke="var(--color-line)"
            stroke-width="1"
          />
          <text
            :for={{value, py} <- @gridlines}
            x="36"
            y={py + 3}
            text-anchor="end"
            fill="var(--color-faint)"
            font-size="9"
            font-family="var(--font-mono)"
          >
            {round(value)}
          </text>
        </g>

        <g>
          <rect
            :for={{day, i} <- @bars}
            x={@x.(i) - @bar_width / 2}
            y={@y.(day.load)}
            width={@bar_width}
            height={max(@baseline - @y.(day.load), 0.5)}
            fill="var(--color-signal)"
            opacity="0.22"
          />
        </g>

        <path
          d={@atl_path}
          fill="none"
          stroke="var(--color-fatigue)"
          stroke-width="1.2"
          opacity="0.85"
        />
        <path d={@ctl_path} fill="none" stroke="var(--color-signal)" stroke-width="2" />

        <g>
          <text
            :for={{label, px} <- @x_labels}
            x={px}
            y={@height - 6}
            text-anchor="middle"
            fill="var(--color-faint)"
            font-size="9"
            font-family="var(--font-mono)"
          >
            {label}
          </text>
        </g>
      </svg>
    </.chart_frame>
    """
  end

  # -- forme du jour ----------------------------------------------------------

  attr :days, :list, required: true
  attr :width, :integer, default: 1400
  attr :height, :integer, default: 100
  attr :class, :string, default: nil

  @doc """
  Bande de forme : l'ecart entre charge chronique et charge aigue.

  Separee du graphe principal plutot que posee sur un second axe. Un double axe
  obligerait a verifier a quelle echelle appartient chaque trait avant de lire
  quoi que ce soit, pour une grandeur dont seul le signe importe vraiment.
  """
  def form_strip(assigns) do
    width = assigns.width
    pad_left = 42
    pad_right = 12

    days = assigns.days
    n = max(length(days), 1)

    bound =
      days
      |> Enum.map(&abs(&1.tsb || 0.0))
      |> Enum.max(fn -> 25.0 end)
      |> then(&max(&1 * 1.1, 10.0))

    x = fn i -> scale(i, {0, max(n - 1, 1)}, {pad_left, width - pad_right}) end
    y = fn v -> scale(v, {-bound, bound}, {assigns.height - 2, 2}) end

    assigns =
      assigns
      |> assign(:zero, y.(0.0))
      |> assign(:bar_width, max((width - pad_left - pad_right) / n * 0.8, 0.8))
      |> assign(:points, Enum.with_index(days))
      |> assign(:x, x)
      |> assign(:y, y)

    ~H"""
    <svg
      viewBox={"0 0 #{@width} #{@height}"}
      class={@class}
      style={aspect(@width, @height)}
      role="img"
    >
      <title>Forme du jour</title>

      <line
        x1="42"
        x2={@width - 12}
        y1={@zero}
        y2={@zero}
        stroke="var(--color-line-bright)"
        stroke-width="1"
      />

      <rect
        :for={{day, i} <- @points}
        x={@x.(i) - @bar_width / 2}
        y={min(@y.(day.tsb || 0.0), @zero)}
        width={@bar_width}
        height={max(abs(@zero - @y.(day.tsb || 0.0)), 0.4)}
        fill={if (day.tsb || 0.0) >= 0, do: "var(--color-form)", else: "var(--color-alert)"}
        opacity="0.55"
      />
    </svg>
    """
  end

  # -- courbe vitesse-duree ---------------------------------------------------

  attr :efforts, :list,
    required: true,
    doc: "meilleurs efforts, avec `:duration_s` et `:speed_ms`"

  attr :cs, :any, default: nil, doc: "ajustement de vitesse critique, pour tracer le modele"
  attr :id, :string, default: "curve-chart"
  attr :width, :integer, default: 950
  attr :height, :integer, default: 420
  attr :class, :string, default: nil

  @doc """
  Courbe vitesse-duree, avec le modele de vitesse critique superpose.

  L'axe des durees est logarithmique. Le modele est trace en continu sur toute
  la plage, mais en trait plein seulement la ou il est valide (deux a vingt
  minutes) et en pointille au dela : c'est la facon la plus honnete de montrer
  qu'une extrapolation reste une extrapolation.
  """
  def curve_chart(assigns) do
    width = assigns.width
    pad_left = 52
    pad_right = 14
    pad_top = 12
    pad_bottom = 24

    efforts = Enum.sort_by(assigns.efforts, & &1.duration_s)

    if efforts == [] do
      assign(assigns, :empty, true) |> empty_chart()
    else
      d_min = efforts |> Enum.map(& &1.duration_s) |> Enum.min() |> max(1)
      d_max = efforts |> Enum.map(& &1.duration_s) |> Enum.max()
      speeds = Enum.map(efforts, & &1.speed_ms)
      s_min = Enum.min(speeds) * 0.94
      s_max = Enum.max(speeds) * 1.04

      x = fn d -> log_scale(d, {d_min, d_max}, {pad_left, width - pad_right}) end
      y = fn s -> scale(s, {s_min, s_max}, {assigns.height - pad_bottom, pad_top}) end

      {valid_path, extrapolated_path} = model_paths(assigns.cs, d_min, d_max, x, y)

      assigns =
        assigns
        |> assign(:points, Enum.map(efforts, &{x.(&1.duration_s), y.(&1.speed_ms), &1}))
        |> assign(:valid_path, valid_path)
        |> assign(:extrapolated_path, extrapolated_path)
        |> assign(:pace_ticks, pace_ticks(s_min, s_max, y))
        |> assign(:duration_ticks, duration_ticks(d_min, d_max, x))
        |> assign(:empty, false)
        |> assign(:hover, curve_hover(efforts, x, assigns.width))

      ~H"""
      <.chart_frame id={@id} hover={@hover} class={@class}>
        <svg
          viewBox={"0 0 #{@width} #{@height}"}
          style={aspect(@width, @height)}
          role="img"
        >
          <title>Courbe vitesse-duree</title>

          <g>
            <line
              :for={{_label, py} <- @pace_ticks}
              x1="52"
              x2={@width - 14}
              y1={py}
              y2={py}
              stroke="var(--color-line)"
              stroke-width="1"
            />
            <text
              :for={{label, py} <- @pace_ticks}
              x="46"
              y={py + 3}
              text-anchor="end"
              fill="var(--color-faint)"
              font-size="9"
              font-family="var(--font-mono)"
            >
              {label}
            </text>
          </g>

          <path
            :if={@extrapolated_path}
            d={@extrapolated_path}
            fill="none"
            stroke="var(--color-signal)"
            stroke-width="1.2"
            stroke-dasharray="3 3"
            opacity="0.5"
          />
          <path
            :if={@valid_path}
            d={@valid_path}
            fill="none"
            stroke="var(--color-signal)"
            stroke-width="1.8"
            opacity="0.9"
          />

          <circle
            :for={{px, py, _effort} <- @points}
            cx={px}
            cy={py}
            r="2.4"
            fill="var(--color-ink)"
            stroke="var(--color-text)"
            stroke-width="1.1"
          />

          <g>
            <text
              :for={{label, px} <- @duration_ticks}
              x={px}
              y={@height - 7}
              text-anchor="middle"
              fill="var(--color-faint)"
              font-size="9"
              font-family="var(--font-mono)"
            >
              {label}
            </text>
          </g>
        </svg>
      </.chart_frame>
      """
    end
  end

  # -- progression de la vitesse critique -------------------------------------

  attr :fits, :list,
    required: true,
    doc: "historique d'ajustements, avec `:fitted_on` et `:cs_ms`"

  attr :id, :string, default: "progression-chart"

  attr :width, :integer, default: 680
  attr :height, :integer, default: 260
  attr :class, :string, default: nil

  @doc "Derive de la vitesse critique dans le temps — la base de la projection."
  def progression_chart(assigns) do
    width = assigns.width
    pad_left = 52
    pad_right = 14
    pad_top = 12
    pad_bottom = 20

    fits = assigns.fits

    if length(fits) < 2 do
      assign(assigns, :empty, true) |> empty_chart()
    else
      first = hd(fits).fitted_on
      span = max(Date.diff(List.last(fits).fitted_on, first), 1)
      values = Enum.map(fits, & &1.cs_ms)
      lo = Enum.min(values)
      hi = Enum.max(values)
      # Marge minimale de 0.05 m/s : sur une periode sans progression, un
      # domaine ajuste au millimetre transformerait du bruit en montagnes.
      margin = max((hi - lo) * 0.18, 0.05)

      x = fn date -> scale(Date.diff(date, first), {0, span}, {pad_left, width - pad_right}) end
      y = fn v -> scale(v, {lo - margin, hi + margin}, {assigns.height - pad_bottom, pad_top}) end

      path =
        fits
        |> Enum.map(fn f -> {x.(f.fitted_on), y.(f.cs_ms)} end)
        |> to_path()

      area =
        path <>
          " L #{x.(List.last(fits).fitted_on)} #{assigns.height - pad_bottom}" <>
          " L #{x.(first)} #{assigns.height - pad_bottom} Z"

      assigns =
        assigns
        |> assign(:path, path)
        |> assign(:area, area)
        |> assign(:pace_ticks, pace_ticks(lo - margin, hi + margin, y))
        |> assign(:empty, false)
        |> assign(:hover, progression_hover(fits, x, assigns.width))

      ~H"""
      <.chart_frame id={@id} hover={@hover} class={@class}>
        <svg
          viewBox={"0 0 #{@width} #{@height}"}
          style={aspect(@width, @height)}
          role="img"
        >
          <title>Progression de la vitesse critique</title>

          <defs>
            <linearGradient id="cs-area" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stop-color="var(--color-signal)" stop-opacity="0.26" />
              <stop offset="100%" stop-color="var(--color-signal)" stop-opacity="0" />
            </linearGradient>
          </defs>

          <g>
            <line
              :for={{_label, py} <- @pace_ticks}
              x1="52"
              x2={@width - 14}
              y1={py}
              y2={py}
              stroke="var(--color-line)"
              stroke-width="1"
            />
            <text
              :for={{label, py} <- @pace_ticks}
              x="46"
              y={py + 3}
              text-anchor="end"
              fill="var(--color-faint)"
              font-size="9"
              font-family="var(--font-mono)"
            >
              {label}
            </text>
          </g>

          <path d={@area} fill="url(#cs-area)" />
          <path d={@path} fill="none" stroke="var(--color-signal)" stroke-width="2" />
        </svg>
      </.chart_frame>
      """
    end
  end

  # -- mesure quotidienne -----------------------------------------------------

  attr :points, :list, required: true, doc: "liste de `{date, valeur}`, triee"
  attr :id, :string, required: true
  attr :series_label, :string, default: "valeur"
  attr :unit, :string, default: ""
  attr :baseline, :any, default: nil, doc: "`{bas, haut}` de la fourchette personnelle"
  attr :color, :string, default: "var(--color-signal)"
  attr :width, :integer, default: 680
  attr :height, :integer, default: 150
  attr :invert, :boolean, default: false, doc: "vers le bas, c'est mieux (FC au repos, stress)"
  attr :class, :string, default: nil

  @doc """
  Serie d'une mesure quotidienne, avec sa fourchette personnelle en fond.

  La bande de normale est ce qui rend la courbe lisible : une variabilite
  cardiaque a 78 ms ne dit rien seule, mais voir qu'elle flotte au milieu
  d'une fourchette 61-104 dit tout en un coup d'oeil.

  Les trous ne sont pas combles. Une nuit sans la montre doit laisser une
  interruption, pas un segment qui relie deux semaines et laisse croire a une
  mesure continue.
  """
  def daily_chart(assigns) do
    points = assigns.points

    if length(points) < 2 do
      empty_chart(assigns)
    else
      pad_left = 44
      pad_right = 12
      pad_top = 10
      pad_bottom = 18

      values = Enum.map(points, &elem(&1, 1))
      {lo, hi} = domain(values, assigns.baseline)
      first = points |> List.first() |> elem(0)
      span = max(Date.diff(points |> List.last() |> elem(0), first), 1)

      x = fn date ->
        scale(Date.diff(date, first), {0, span}, {pad_left, assigns.width - pad_right})
      end

      y = fn value -> scale(value, {lo, hi}, {assigns.height - pad_bottom, pad_top}) end

      assigns =
        assigns
        |> assign(:segments, segments(points, x, y))
        |> assign(:band, band(assigns.baseline, y, pad_left, assigns.width - pad_right))
        |> assign(:ticks, value_ticks(lo, hi, y))
        |> assign(:last, last_point(points, x, y))
        |> assign(:empty, false)
        |> assign(
          :hover,
          daily_hover(points, x, assigns.width, assigns.series_label, assigns.unit, assigns.color)
        )

      ~H"""
      <.chart_frame id={@id} hover={@hover} class={@class}>
        <svg
          viewBox={"0 0 #{@width} #{@height}"}
          style={aspect(@width, @height)}
          role="img"
        >
          <g>
            <line
              :for={{_label, py} <- @ticks}
              x1={44}
              x2={@width - 12}
              y1={py}
              y2={py}
              stroke="var(--color-line)"
              stroke-width="1"
            />
            <text
              :for={{label, py} <- @ticks}
              x="38"
              y={py + 3}
              text-anchor="end"
              fill="var(--color-faint)"
              font-size="9"
              font-family="var(--font-mono)"
            >
              {label}
            </text>
          </g>

          <rect
            :if={@band}
            x={elem(@band, 0)}
            y={elem(@band, 1)}
            width={elem(@band, 2)}
            height={elem(@band, 3)}
            fill="var(--color-form)"
            opacity="0.09"
          />

          <path :for={segment <- @segments} d={segment} fill="none" stroke={@color} stroke-width="1.6" />

          <circle :if={@last} cx={elem(@last, 0)} cy={elem(@last, 1)} r="2.6" fill={@color} />
        </svg>
      </.chart_frame>
      """
    end
  end

  # Les trous de plus d'une semaine coupent le trait. En deca, relier reste
  # honnete — ces mesures evoluent lentement — et evite une courbe hachee par
  # chaque nuit sans la montre.
  @max_gap_days 7

  defp segments(points, x, y) do
    points
    |> Enum.chunk_while([], &accumulate/2, &flush/1)
    |> Enum.reject(&(length(&1) < 2))
    |> Enum.map(fn run -> run |> Enum.map(fn {d, v} -> {x.(d), y.(v)} end) |> to_path() end)
  end

  defp accumulate({date, _value} = point, [{previous, _} | _] = acc) do
    if Date.diff(date, previous) > @max_gap_days do
      {:cont, Enum.reverse(acc), [point]}
    else
      {:cont, [point | acc]}
    end
  end

  defp accumulate(point, acc), do: {:cont, [point | acc]}

  defp flush([]), do: {:cont, []}
  defp flush(acc), do: {:cont, Enum.reverse(acc), []}

  # Le domaine englobe la fourchette personnelle meme quand les valeurs n'y
  # vont pas : sans cela la bande de normale sortirait du cadre et la courbe
  # paraitrait centree alors qu'elle est en bord de fourchette.
  defp domain(values, baseline) do
    candidates =
      case baseline do
        {low, high} when is_number(low) and is_number(high) -> values ++ [low, high]
        _none -> values
      end

    lo = Enum.min(candidates)
    hi = Enum.max(candidates)
    margin = max((hi - lo) * 0.12, abs(hi) * 0.02 + 0.5)

    {lo - margin, hi + margin}
  end

  defp band(nil, _y, _x0, _x1), do: nil

  defp band({low, high}, y, x0, x1) when is_number(low) and is_number(high) do
    top = y.(high)
    bottom = y.(low)
    {x0, top, x1 - x0, max(bottom - top, 1)}
  end

  defp band(_baseline, _y, _x0, _x1), do: nil

  defp value_ticks(lo, hi, y) do
    Enum.map([0.15, 0.5, 0.85], fn fraction ->
      value = lo + (hi - lo) * fraction
      {format_tick(value), y.(value)}
    end)
  end

  defp format_tick(value) when abs(value) >= 100, do: value |> round() |> Integer.to_string()
  defp format_tick(value) when abs(value) >= 10, do: value |> round() |> Integer.to_string()
  defp format_tick(value), do: value |> Float.round(1) |> to_string()

  defp last_point(points, x, y) do
    {date, value} = List.last(points)
    {x.(date), y.(value)}
  end

  # -- sommeil empile ----------------------------------------------------------

  attr :id, :string, default: "sleep-chart"
  attr :nights, :list, required: true, doc: "lignes de `DailyWellness` portant les phases"
  attr :width, :integer, default: 1400
  attr :height, :integer, default: 220
  attr :class, :string, default: nil

  @phases [
    {:sleep_deep_s, "profond", "var(--color-signal)"},
    {:sleep_rem_s, "paradoxal", "var(--color-form)"},
    {:sleep_light_s, "leger", "var(--color-signal-deep)"},
    {:sleep_awake_s, "eveil", "var(--color-alert)"}
  ]

  @doc """
  Phases de sommeil, empilees nuit par nuit.

  L'empilement est le bon outil ici parce que les phases forment un tout : ce
  qu'on lit, c'est a la fois la duree totale — la hauteur de la colonne — et
  sa composition. Quatre courbes separees obligeraient a additionner de tete
  pour retrouver la duree, qui est pourtant la premiere chose qu'on cherche.

  L'ordre d'empilement place le profond en bas : c'est la phase la plus
  reguliere, donc celle qui sert de socle visuel stable d'une nuit a l'autre.
  """
  def sleep_chart(assigns) do
    nights = Enum.filter(assigns.nights, &is_number(&1.sleep_total_s))

    if length(nights) < 2 do
      empty_chart(assigns)
    else
      pad_left = 44
      pad_right = 12
      pad_top = 10
      pad_bottom = 18

      max_total =
        nights
        |> Enum.map(&night_total/1)
        |> Enum.max()
        |> then(&max(&1 * 1.05, 3600.0))

      n = length(nights)
      x_range = {pad_left, assigns.width - pad_right}

      x = fn i -> scale(i, {0, max(n - 1, 1)}, x_range) end

      y = fn seconds ->
        scale(seconds, {0.0, max_total}, {assigns.height - pad_bottom, pad_top})
      end

      assigns =
        assigns
        |> assign(:bars, stacked_bars(nights, x, y, assigns.height - pad_bottom))
        |> assign(:bar_width, max((assigns.width - pad_left - pad_right) / n * 0.72, 1.0))
        |> assign(:ticks, hour_ticks(max_total, y))
        |> assign(:phases, @phases)
        |> assign(:hover, sleep_hover(nights, x, assigns.width))
        |> assign(:empty, false)

      ~H"""
      <.chart_frame id={@id} hover={@hover} class={@class}>
        <svg viewBox={"0 0 #{@width} #{@height}"} style={aspect(@width, @height)} role="img">
          <g>
            <line
              :for={{_label, py} <- @ticks}
              x1="44"
              x2={@width - 12}
              y1={py}
              y2={py}
              stroke="var(--color-line)"
              stroke-width="1"
            />
            <text
              :for={{label, py} <- @ticks}
              x="38"
              y={py + 3}
              text-anchor="end"
              fill="var(--color-faint)"
              font-size="9"
              font-family="var(--font-mono)"
            >
              {label}
            </text>
          </g>

          <g :for={bar <- @bars}>
            <rect
              :for={piece <- bar}
              x={piece.x - @bar_width / 2}
              y={piece.y}
              width={@bar_width}
              height={piece.height}
              fill={piece.color}
              opacity="0.85"
            />
          </g>
        </svg>
      </.chart_frame>
      """
    end
  end

  defp night_total(night) do
    @phases
    |> Enum.map(fn {field, _label, _color} -> Map.get(night, field) || 0 end)
    |> Enum.sum()
    |> Kernel.*(1.0)
  end

  defp stacked_bars(nights, x, y, baseline) do
    nights
    |> Enum.with_index()
    |> Enum.map(fn {night, i} ->
      {pieces, _top} =
        Enum.map_reduce(@phases, 0.0, fn {field, _label, color}, stacked ->
          seconds = (Map.get(night, field) || 0) * 1.0
          top = stacked + seconds

          piece = %{
            x: x.(i),
            y: y.(top),
            height: max(baseline - y.(seconds) - (baseline - y.(0.0)), 0.4),
            color: color
          }

          {piece, top}
        end)

      pieces
    end)
  end

  defp hour_ticks(max_total, y) do
    hours = ceil(max_total / 3600)
    step = if hours > 10, do: 3, else: 2

    2..hours//step
    |> Enum.map(&{"#{&1} h", y.(&1 * 3600.0)})
  end

  defp sleep_hover(nights, x, width) do
    nights
    |> Enum.with_index()
    |> Enum.map(fn {night, i} ->
      %{
        x: percent(x.(i), width),
        label: long_date(night.date),
        rows:
          [%{k: "total", v: hours_text(night_total(night)), c: "var(--color-text)"}] ++
            Enum.map(@phases, fn {field, label, color} ->
              %{k: label, v: hours_text(Map.get(night, field)), c: color}
            end) ++
            [%{k: "score", v: score_text(night.sleep_score), c: "var(--color-faint)"}]
      }
    end)
  end

  defp hours_text(nil), do: "—"
  defp hours_text(0), do: "—"

  defp hours_text(seconds) do
    total = round(seconds)

    "#{div(total, 3600)} h #{total |> rem(3600) |> div(60) |> to_string() |> String.pad_leading(2, "0")}"
  end

  defp score_text(nil), do: "—"
  defp score_text(score), do: to_string(score)

  @doc "Les phases et leurs couleurs, pour construire une legende coherente."
  def sleep_phases, do: @phases

  # -- deux series a echelles differentes ---------------------------------------

  attr :id, :string, default: "overlay-chart"
  attr :mine, :list, required: true, doc: "liste de `{date, valeur}`"
  attr :theirs, :list, required: true, doc: "liste de `{date, valeur}`"
  attr :mine_label, :string, default: "Soleus"
  attr :theirs_label, :string, default: "Garmin"
  attr :width, :integer, default: 1400
  attr :height, :integer, default: 220
  attr :class, :string, default: nil

  @doc """
  Superpose deux series que leurs echelles rendent incomparables en valeur.

  La charge de Soleus est un score de stress rapporte a la vitesse critique :
  une heure au seuil vaut 100. Celle de Garmin est un EPOC estime, qui se
  compte en centaines. Les tracer sur un axe commun ecraserait l'une contre
  zero.

  Chaque serie est donc ramenee a sa propre amplitude, et l'axe des ordonnees
  **n'est pas gradue** : il n'a pas d'unite commune, et en afficher une serait
  mentir. Ce que le graphe montre est la seule chose comparable, la forme —
  les deux modeles montent-ils et redescendent-ils ensemble.
  """
  def overlay_chart(assigns) do
    mine = assigns.mine
    theirs = assigns.theirs

    if length(mine) < 2 or length(theirs) < 2 do
      empty_chart(assigns)
    else
      pad = {46, 12, 10, 18}
      dates = Enum.map(mine ++ theirs, &elem(&1, 0))
      first = Enum.min_by(dates, &Date.to_erl/1)
      last = Enum.max_by(dates, &Date.to_erl/1)
      span = max(Date.diff(last, first), 1)

      {left, right, top, bottom} = pad
      x = fn date -> scale(Date.diff(date, first), {0, span}, {left, assigns.width - right}) end

      assigns =
        assigns
        |> assign(:mine_path, normalised_path(mine, x, assigns.height, top, bottom))
        |> assign(:theirs_path, normalised_path(theirs, x, assigns.height, top, bottom))
        |> assign(:hover, overlay_hover(mine, theirs, x, assigns))
        |> assign(:empty, false)

      ~H"""
      <.chart_frame id={@id} hover={@hover} class={@class}>
        <svg viewBox={"0 0 #{@width} #{@height}"} style={aspect(@width, @height)} role="img">
          <path d={@theirs_path} fill="none" stroke="var(--color-fatigue)" stroke-width="1.4" />
          <path d={@mine_path} fill="none" stroke="var(--color-signal)" stroke-width="2" />
        </svg>
      </.chart_frame>
      """
    end
  end

  defp normalised_path(points, x, height, top, bottom) do
    values = Enum.map(points, &elem(&1, 1))
    {lo, hi} = Enum.min_max(values)
    span = max(hi - lo, 1.0e-9)

    points
    |> Enum.map(fn {date, value} ->
      {x.(date), scale((value - lo) / span, {0.0, 1.0}, {height - bottom, top})}
    end)
    |> to_path()
  end

  defp overlay_hover(mine, theirs, x, assigns) do
    theirs_by_date = Map.new(theirs)

    Enum.map(mine, fn {date, value} ->
      %{
        x: percent(x.(date), assigns.width),
        label: long_date(date),
        rows: [
          %{k: assigns.mine_label, v: round1(value), c: "var(--color-signal)"},
          %{
            k: assigns.theirs_label,
            v: round1(Map.get(theirs_by_date, date)),
            c: "var(--color-fatigue)"
          }
        ]
      }
    end)
  end

  # -- serie d'une seance ------------------------------------------------------

  attr :id, :string, required: true
  attr :points, :list, required: true, doc: "liste de `{seconde, valeur}`"
  attr :label, :string, required: true
  attr :unit, :string, default: ""
  attr :color, :string, default: "var(--color-signal)"
  attr :pace, :boolean, default: false, doc: "valeurs en m/s, a lire comme une allure"
  attr :width, :integer, default: 1200
  attr :height, :integer, default: 150
  attr :class, :string, default: nil

  @doc """
  Une mesure au fil d'une seance : frequence cardiaque, allure, altitude.

  Quand `pace` est vrai, l'axe est **inverse** : une allure plus rapide se
  lit plus haut, alors que la vitesse qui la porte est un nombre plus grand.
  Laisser l'axe dans le sens naturel de la vitesse donnerait un graphe ou les
  cotes montent et les accelerations aussi, ce qui se lit mal.
  """
  def stream_chart(assigns) do
    points = assigns.points

    if length(points) < 2 do
      empty_chart(assigns)
    else
      pad_left = 46
      pad_right = 12
      pad_top = 10
      pad_bottom = 18

      values = Enum.map(points, &elem(&1, 1))
      {lo, hi} = Enum.min_max(values)
      margin = max((hi - lo) * 0.1, 0.01)
      last_t = points |> List.last() |> elem(0)

      x = fn t -> scale(t, {0, max(last_t, 1)}, {pad_left, assigns.width - pad_right}) end
      y = fn v -> scale(v, {lo - margin, hi + margin}, {assigns.height - pad_bottom, pad_top}) end

      assigns =
        assigns
        |> assign(:path, points |> Enum.map(fn {t, v} -> {x.(t), y.(v)} end) |> to_path())
        |> assign(:ticks, stream_ticks(lo - margin, hi + margin, y, assigns.pace))
        |> assign(:time_ticks, time_ticks(last_t, x))
        |> assign(:hover, stream_hover(points, x, assigns))
        |> assign(:empty, false)

      ~H"""
      <.chart_frame id={@id} hover={@hover} class={@class}>
        <svg viewBox={"0 0 #{@width} #{@height}"} style={aspect(@width, @height)} role="img">
          <g>
            <line
              :for={{_label, py} <- @ticks}
              x1="46"
              x2={@width - 12}
              y1={py}
              y2={py}
              stroke="var(--color-line)"
              stroke-width="1"
            />
            <text
              :for={{label, py} <- @ticks}
              x="40"
              y={py + 3}
              text-anchor="end"
              fill="var(--color-faint)"
              font-size="9"
              font-family="var(--font-mono)"
            >
              {label}
            </text>
          </g>

          <path d={@path} fill="none" stroke={@color} stroke-width="1.5" />

          <g>
            <text
              :for={{label, px} <- @time_ticks}
              x={px}
              y={@height - 5}
              text-anchor="middle"
              fill="var(--color-faint)"
              font-size="9"
              font-family="var(--font-mono)"
            >
              {label}
            </text>
          </g>
        </svg>
      </.chart_frame>
      """
    end
  end

  # L'inversion de l'axe pour les allures se fait par les graduations, pas par
  # les donnees : la courbe reste tracee sur la vitesse, seules les etiquettes
  # changent de sens de lecture.
  defp stream_ticks(lo, hi, y, true) do
    Enum.map([0.15, 0.5, 0.85], fn fraction ->
      value = lo + (hi - lo) * fraction
      {Pace.format(value), y.(value)}
    end)
  end

  defp stream_ticks(lo, hi, y, false) do
    Enum.map([0.15, 0.5, 0.85], fn fraction ->
      value = lo + (hi - lo) * fraction
      {format_tick(value), y.(value)}
    end)
  end

  defp time_ticks(last_t, x) do
    step = nice_step(last_t)

    0..last_t//step
    |> Enum.map(&{Pace.format_duration(&1), x.(&1)})
  end

  # Un pas qui tombe rond et donne cinq a huit graduations, quelle que soit la
  # duree de la seance.
  defp nice_step(last_t) do
    [60, 120, 300, 600, 900, 1800, 3600]
    |> Enum.find(3600, &(last_t / &1 <= 8))
  end

  defp stream_hover(points, x, assigns) do
    Enum.map(points, fn {t, value} ->
      %{
        x: percent(x.(t), assigns.width),
        label: Pace.format_duration(t),
        rows: [%{k: assigns.label, v: stream_value(value, assigns), c: assigns.color}]
      }
    end)
  end

  defp stream_value(value, %{pace: true}), do: "#{Pace.format(value)} /km"
  defp stream_value(value, assigns), do: "#{round1(value)}#{assigns.unit}"

  # -- survol -----------------------------------------------------------------

  # Un point par jour portant les quatre series d'un coup : au survol, ce
  # qu'on veut savoir n'est pas une valeur isolee mais l'etat du jour.
  defp load_hover(days, x, width) do
    days
    |> Enum.with_index()
    |> Enum.map(fn {day, i} ->
      %{
        x: percent(x.(i), width),
        label: long_date(day.date),
        rows:
          Enum.map(
            [
              {"charge chronique", round1(day.ctl), "var(--color-signal)"},
              {"charge aigue", round1(day.atl), "var(--color-fatigue)"},
              {"forme", signed1(day.tsb), form_color(day.tsb)},
              daily_load_row(day)
            ],
            fn {k, v, c} -> %{k: k, v: v, c: c} end
          )
      }
    end)
  end

  defp daily_load_row(%{load: load}) when is_number(load) and load > 0,
    do: {"charge du jour", round1(load), "var(--color-signal)"}

  defp daily_load_row(_day), do: {"charge du jour", "repos", "var(--color-faint)"}

  defp form_color(tsb) when is_number(tsb) and tsb >= 0, do: "var(--color-form)"
  defp form_color(_tsb), do: "var(--color-alert)"

  defp progression_hover(fits, x, width) do
    Enum.map(fits, fn fit ->
      %{
        x: percent(x.(fit.fitted_on), width),
        label: long_date(fit.fitted_on),
        rows: [
          %{k: "vitesse critique", v: "#{Pace.format(fit.cs_ms)} /km", c: "var(--color-signal)"},
          %{k: "en m/s", v: round3(fit.cs_ms), c: "var(--color-faint)"}
        ]
      }
    end)
  end

  defp curve_hover(efforts, x, width) do
    Enum.map(efforts, fn effort ->
      %{
        x: percent(x.(effort.duration_s), width),
        label: Pace.format_duration(effort.duration_s),
        rows: [
          %{k: "allure", v: "#{Pace.format(effort.speed_ms)} /km", c: "var(--color-text)"},
          %{k: "distance", v: "#{round(effort.distance_m)} m", c: "var(--color-faint)"}
        ]
      }
    end)
  end

  defp daily_hover(points, x, width, label, unit, color) do
    Enum.map(points, fn {date, value} ->
      %{
        x: percent(x.(date), width),
        label: long_date(date),
        rows: [%{k: label, v: "#{round1(value)}#{unit}", c: color}]
      }
    end)
  end

  @long_months ~w(janvier fevrier mars avril mai juin juillet aout septembre octobre novembre decembre)

  defp long_date(%Date{} = date),
    do: "#{date.day} #{Enum.at(@long_months, date.month - 1)} #{date.year}"

  defp round1(nil), do: "—"
  defp round1(value) when is_integer(value), do: Integer.to_string(value)
  defp round1(value) when is_number(value), do: value |> Float.round(1) |> to_string()

  defp round3(nil), do: "—"
  defp round3(value) when is_number(value), do: value |> Float.round(3) |> to_string()

  defp signed1(nil), do: "—"
  defp signed1(value) when value >= 0, do: "+" <> round1(value)
  defp signed1(value), do: round1(value)

  # -- primitives -------------------------------------------------------------

  defp empty_chart(assigns) do
    ~H"""
    <div class="flex h-24 items-center justify-center text-xs" style="color: var(--color-faint)">
      Pas encore assez de donnees
    </div>
    """
  end

  defp line_path(days, x, y, key) do
    days
    |> Enum.with_index()
    |> Enum.map(fn {day, i} -> {x.(i), y.(Map.get(day, key))} end)
    |> to_path()
  end

  defp to_path([]), do: ""

  defp to_path([{x0, y0} | rest]) do
    Enum.reduce(rest, "M #{f(x0)} #{f(y0)}", fn {px, py}, acc ->
      acc <> " L #{f(px)} #{f(py)}"
    end)
  end

  # La courbe du modele est echantillonnee geometriquement et non lineairement :
  # l'axe est logarithmique, donc un pas constant en secondes donnerait cent
  # points tasses a droite et trois a gauche.
  defp model_paths(nil, _d_min, _d_max, _x, _y), do: {nil, nil}

  defp model_paths(cs, d_min, d_max, x, y) do
    {valid_lo, valid_hi} = CriticalSpeed.window()

    samples =
      for i <- 0..80 do
        d = d_min * :math.pow(d_max / d_min, i / 80)
        {d, {x.(d), y.(cs.cs_ms + cs.d_prime_m / d)}}
      end

    valid = samples |> Enum.filter(fn {d, _} -> d >= valid_lo and d <= valid_hi end)

    {
      if(length(valid) > 1, do: valid |> Enum.map(&elem(&1, 1)) |> to_path()),
      samples |> Enum.map(&elem(&1, 1)) |> to_path()
    }
  end

  # Graduations de l'axe des vitesses, libellees en allure : un coureur lit des
  # minutes par kilometre, pas des metres par seconde.
  defp pace_ticks(s_min, s_max, y) do
    # On gradue sur des allures rondes de dix secondes, ce qui tombe sur des
    # vitesses irregulieres mais sur des libelles lisibles.
    p_fast = Pace.per_km(s_max)
    p_slow = Pace.per_km(s_min)

    start = ceil(p_fast / 10) * 10
    stop = floor(p_slow / 10) * 10

    step = max(round((stop - start) / 4 / 10) * 10, 10)

    start..stop//step
    |> Enum.map(fn pace -> {Pace.format_duration(pace), y.(Pace.from_per_km(pace))} end)
  end

  @duration_ticks [5, 15, 30, 60, 120, 300, 600, 1200, 1800, 3600, 7200]

  defp duration_ticks(d_min, d_max, x) do
    @duration_ticks
    |> Enum.filter(&(&1 >= d_min and &1 <= d_max))
    |> Enum.map(&{Pace.format_duration(&1), x.(&1)})
  end

  @months ~w(janv. fevr. mars avr. mai juin juil. aout sept. oct. nov. dec.)

  # Une graduation au premier jour de chaque mois, et seulement si le graphe est
  # assez large pour que les libelles ne se chevauchent pas.
  defp month_ticks(days, x) do
    step = if length(days) > 240, do: 2, else: 1

    days
    |> Enum.with_index()
    |> Enum.filter(fn {day, _i} -> day.date.day == 1 and rem(day.date.month, step) == 0 end)
    |> Enum.map(fn {day, i} -> {Enum.at(@months, day.date.month - 1), x.(i)} end)
  end

  # Le rapport d'aspect du viewBox, impose en CSS. Voir le @moduledoc.
  defp aspect(width, height), do: "aspect-ratio: #{width} / #{height}"

  defp f(value) when is_float(value), do: Float.round(value, 2)
  defp f(value), do: value
end
