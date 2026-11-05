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

  Tous les graphes dessinent dans un `viewBox` en coordonnees logiques et se
  mettent a l'echelle par CSS. Les tailles de police sont donc exprimees dans
  le repere du `viewBox`, pas en pixels ecran.
  """

  use Phoenix.Component

  alias Soleus.Analytics.CriticalSpeed
  alias Soleus.Analytics.Pace

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
  attr :height, :integer, default: 200
  attr :class, :string, default: nil

  @doc """
  Charge chronique, charge aigue et charge quotidienne sur une meme grille.

  Les barres de charge quotidienne sont dessinees avant les courbes, et en
  violet tres dilue : ce sont les donnees brutes, les deux courbes en sont la
  lecture. L'inverse — des barres saturees derriere des traits fins — rendrait
  la tendance illisible, qui est pourtant la seule chose qu'on vient chercher.
  """
  def load_chart(assigns) do
    width = 1000
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
      |> assign(:width, width)
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

    ~H"""
    <svg viewBox={"0 0 #{@width} #{@height}"} class={@class} preserveAspectRatio="none" role="img">
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

      <path d={@atl_path} fill="none" stroke="var(--color-fatigue)" stroke-width="1.2" opacity="0.85" />
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
    """
  end

  # -- forme du jour ----------------------------------------------------------

  attr :days, :list, required: true
  attr :height, :integer, default: 64
  attr :class, :string, default: nil

  @doc """
  Bande de forme : l'ecart entre charge chronique et charge aigue.

  Separee du graphe principal plutot que posee sur un second axe. Un double axe
  obligerait a verifier a quelle echelle appartient chaque trait avant de lire
  quoi que ce soit, pour une grandeur dont seul le signe importe vraiment.
  """
  def form_strip(assigns) do
    width = 1000
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
      |> assign(:width, width)
      |> assign(:zero, y.(0.0))
      |> assign(:bar_width, max((width - pad_left - pad_right) / n * 0.8, 0.8))
      |> assign(:points, Enum.with_index(days))
      |> assign(:x, x)
      |> assign(:y, y)

    ~H"""
    <svg viewBox={"0 0 #{@width} #{@height}"} class={@class} preserveAspectRatio="none" role="img">
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
  attr :height, :integer, default: 240
  attr :class, :string, default: nil

  @doc """
  Courbe vitesse-duree, avec le modele de vitesse critique superpose.

  L'axe des durees est logarithmique. Le modele est trace en continu sur toute
  la plage, mais en trait plein seulement la ou il est valide (deux a vingt
  minutes) et en pointille au dela : c'est la facon la plus honnete de montrer
  qu'une extrapolation reste une extrapolation.
  """
  def curve_chart(assigns) do
    width = 1000
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
        |> assign(:width, width)
        |> assign(:points, Enum.map(efforts, &{x.(&1.duration_s), y.(&1.speed_ms), &1}))
        |> assign(:valid_path, valid_path)
        |> assign(:extrapolated_path, extrapolated_path)
        |> assign(:pace_ticks, pace_ticks(s_min, s_max, y))
        |> assign(:duration_ticks, duration_ticks(d_min, d_max, x))
        |> assign(:empty, false)

      ~H"""
      <svg viewBox={"0 0 #{@width} #{@height}"} class={@class} preserveAspectRatio="none" role="img">
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
      """
    end
  end

  # -- progression de la vitesse critique -------------------------------------

  attr :fits, :list,
    required: true,
    doc: "historique d'ajustements, avec `:fitted_on` et `:cs_ms`"

  attr :height, :integer, default: 150
  attr :class, :string, default: nil

  @doc "Derive de la vitesse critique dans le temps — la base de la projection."
  def progression_chart(assigns) do
    width = 1000
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
        |> assign(:width, width)
        |> assign(:path, path)
        |> assign(:area, area)
        |> assign(:pace_ticks, pace_ticks(lo - margin, hi + margin, y))
        |> assign(:empty, false)

      ~H"""
      <svg viewBox={"0 0 #{@width} #{@height}"} class={@class} preserveAspectRatio="none" role="img">
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
      """
    end
  end

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

  defp f(value) when is_float(value), do: Float.round(value, 2)
  defp f(value), do: value
end
