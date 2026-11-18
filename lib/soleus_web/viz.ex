defmodule SoleusWeb.Viz do
  @moduledoc """
  Petites visualisations reutilisables : jauge, anneau, barres, sparkline.

  `SoleusWeb.Charts` porte les graphes d'analyse, avec axes et survol. Ici ce
  sont des pictogrammes de donnee : ils se lisent d'un coup d'oeil, sans axe,
  et accompagnent un chiffre plutot qu'ils ne le remplacent. Tous s'animent a
  l'entree par les classes de `app.css` (`.ring`, `.grow-x`, `.grow-y`,
  `.sweep`), et aucun ne demande de JavaScript.
  """

  use Phoenix.Component

  # -- jauge en demi-cercle -----------------------------------------------------

  attr :value, :any, required: true, doc: "valeur affichee, `nil` si inconnue"
  attr :min, :float, required: true
  attr :max, :float, required: true

  attr :zones, :list,
    required: true,
    doc: "`{borne_haute, couleur}` dans l'ordre croissant ; la derniere borne vaut `max`"

  attr :class, :string, default: nil
  slot :inner_block, doc: "contenu centre sous l'arc"

  @doc """
  Demi-cercle decoupe en zones colorees, et un curseur sur la valeur.

  Les zones restent visibles en entier : savoir ou l'on est compte moins que
  savoir de quel cote est la zone voisine.
  """
  def gauge(assigns) do
    {lo, hi} = {assigns.min, assigns.max}
    angle = fn v -> :math.pi() * (1 - (clamp(v, lo, hi) - lo) / (hi - lo)) end

    {arcs, _from} =
      Enum.map_reduce(assigns.zones, lo, fn {upper, color}, from ->
        {%{d: arc(angle.(from), angle.(upper), 80), color: color}, upper}
      end)

    marker =
      if is_number(assigns.value) do
        a = angle.(assigns.value)
        {100 + 80 * :math.cos(a), 92 - 80 * :math.sin(a)}
      end

    assigns = assign(assigns, arcs: arcs, marker: marker)

    ~H"""
    <div class={["relative", @class]}>
      <svg viewBox="0 0 200 104" class="w-full" role="img">
        <path
          :for={{zone, i} <- Enum.with_index(@arcs)}
          d={zone.d}
          fill="none"
          stroke={zone.color}
          stroke-width="12"
          stroke-opacity="0.9"
          class="rise"
          style={"--i: #{i}"}
        />
        <g :if={@marker} class="pop" style="--i: 40">
          <circle cx={elem(@marker, 0)} cy={elem(@marker, 1)} r="10" fill="var(--color-panel)" />
          <circle cx={elem(@marker, 0)} cy={elem(@marker, 1)} r="6.5" fill="var(--color-text)" />
        </g>
      </svg>
      <div class="absolute inset-x-0 bottom-0 flex flex-col items-center">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # Arc de cercle de centre (100, 92), en angles mathematiques. Les zones sont
  # separees d'un leger jour pour que leurs frontieres se lisent.
  defp arc(a0, a1, r) do
    gap = 0.025
    {a0, a1} = {a0 - gap, a1 + gap}
    {x0, y0} = {100 + r * :math.cos(a0), 92 - r * :math.sin(a0)}
    {x1, y1} = {100 + r * :math.cos(a1), 92 - r * :math.sin(a1)}
    "M#{f(x0)},#{f(y0)} A#{r},#{r} 0 0 1 #{f(x1)},#{f(y1)}"
  end

  # -- anneau -------------------------------------------------------------------

  attr :percent, :any, required: true, doc: "remplissage, de 0 a 100"
  attr :color, :string, default: "var(--color-signal)"
  attr :size, :string, default: "h-20 w-20"
  attr :stroke, :integer, default: 9
  slot :inner_block, doc: "contenu au centre de l'anneau"

  @doc "Anneau de progression, rempli a l'entree."
  def ring(assigns) do
    assigns = assign(assigns, :fill, clamp(assigns.percent || 0, 0, 100))

    ~H"""
    <div class={["relative shrink-0", @size]}>
      <svg viewBox="0 0 100 100" class="h-full w-full -rotate-90">
        <circle
          cx="50"
          cy="50"
          r={50 - @stroke / 2}
          fill="none"
          stroke="var(--color-panel-raised)"
          stroke-width={@stroke}
        />
        <circle
          cx="50"
          cy="50"
          r={50 - @stroke / 2}
          fill="none"
          stroke={@color}
          stroke-width={@stroke}
          stroke-linecap="round"
          pathLength="100"
          stroke-dasharray={"#{f(@fill)} 100"}
          class="ring"
        />
      </svg>
      <div class="absolute inset-0 flex flex-col items-center justify-center">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # -- anneau segmente ---------------------------------------------------------

  attr :segments, :list, required: true, doc: "`%{share: 0..100, color: string}`"
  attr :size, :string, default: "h-36 w-36"
  attr :stroke, :integer, default: 14
  slot :inner_block, doc: "contenu au centre"

  @doc """
  Repartition en anneau. Chaque segment est un cercle decale de la somme des
  precedents, et tous se remplissent ensemble a l'entree.
  """
  def donut(assigns) do
    {segments, _offset} =
      Enum.map_reduce(assigns.segments, 0, fn segment, offset ->
        share = clamp(segment.share, 0, 100)
        {Map.merge(segment, %{share: share, offset: offset}), offset + share}
      end)

    assigns = assign(assigns, :items, segments)

    ~H"""
    <div class={["relative shrink-0", @size]}>
      <svg viewBox="0 0 100 100" class="h-full w-full -rotate-90">
        <circle
          cx="50"
          cy="50"
          r={50 - @stroke / 2}
          fill="none"
          stroke="var(--color-panel-raised)"
          stroke-width={@stroke}
        />
        <circle
          :for={segment <- @items}
          cx="50"
          cy="50"
          r={50 - @stroke / 2}
          fill="none"
          stroke={segment.color}
          stroke-width={@stroke}
          pathLength="100"
          stroke-dasharray={"#{f(max(segment.share - 0.8, 0.1))} 100"}
          stroke-dashoffset={f(-segment.offset)}
          class="rise"
        />
      </svg>
      <div class="absolute inset-0 flex flex-col items-center justify-center">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # -- colonnes -----------------------------------------------------------------

  attr :bars, :list,
    required: true,
    doc: "`%{value: number, label: string | nil, color: string | nil, title: string | nil}`"

  attr :color, :string, default: "var(--color-signal)"
  attr :muted, :string, default: "var(--color-line-bright)"
  attr :height, :string, default: "h-24"
  attr :class, :string, default: nil

  @doc """
  Colonnes sans axe, qui poussent a l'entree l'une apres l'autre.

  Une valeur nulle garde une amorce visible : un jour sans course est une
  information, pas une absence de donnee.
  """
  def bars(assigns) do
    top = assigns.bars |> Enum.map(&(&1.value || 0)) |> Enum.max(fn -> 0 end)

    bars =
      assigns.bars
      |> Enum.with_index()
      |> Enum.map(fn {bar, i} ->
        value = bar.value || 0
        share = if top > 0, do: value / top * 100, else: 0
        Map.merge(bar, %{i: i, share: share, empty?: value <= 0})
      end)

    assigns = assign(assigns, :items, bars)

    ~H"""
    <div class={["flex flex-col", @class]}>
      <div class={["flex items-end gap-1.5", @height]}>
        <div
          :for={bar <- @items}
          class="flex h-full flex-1 flex-col justify-end"
          title={bar[:title]}
        >
          <div
            class="grow-y w-full rounded-md"
            style={[
              "--i: #{bar.i};",
              "height: #{if bar.empty?, do: "4px", else: "#{f(max(bar.share, 4))}%"};",
              "background-color: #{if bar.empty?, do: @muted, else: bar[:color] || @color}"
            ]}
          >
          </div>
        </div>
      </div>
      <div :if={Enum.any?(@items, & &1[:label])} class="mt-1.5 flex gap-1.5">
        <span
          :for={bar <- @items}
          class="flex-1 text-center text-[10px] font-semibold uppercase text-faint"
        >
          {bar[:label]}
        </span>
      </div>
    </div>
    """
  end

  # -- barre horizontale --------------------------------------------------------

  attr :percent, :any, required: true
  attr :color, :string, default: "var(--color-signal)"
  attr :i, :integer, default: 0, doc: "rang, pour decaler l'animation"
  attr :class, :string, default: "h-1.5"

  @doc "Barre de proportion, qui s'etire depuis la gauche."
  def hbar(assigns) do
    assigns = assign(assigns, :fill, clamp(assigns.percent || 0, 0, 100))

    ~H"""
    <div class={["w-full overflow-hidden rounded-full bg-panel-raised", @class]}>
      <div
        class="grow-x h-full rounded-full"
        style={"width: #{f(@fill)}%; background-color: #{@color}; --i: #{@i}"}
      >
      </div>
    </div>
    """
  end

  # -- sparkline ----------------------------------------------------------------

  attr :values, :list, required: true, doc: "valeurs dans l'ordre chronologique, `nil` ignore"
  attr :color, :string, default: "var(--color-signal)"
  attr :invert, :boolean, default: false, doc: "vrai quand plus bas est meilleur (une allure)"
  attr :zero, :boolean, default: false, doc: "trace la ligne du zero"
  attr :class, :string, default: "h-10 w-full"

  @doc """
  Tendance sans axe : un trait, un aplat degrade et un point sur la derniere
  valeur. L'echelle est celle des valeurs elles-memes, donc la sparkline dit
  le sens et la forme du mouvement, jamais son amplitude.
  """
  def sparkline(assigns) do
    values = Enum.filter(assigns.values, &is_number/1)

    assigns =
      case values do
        [_, _ | _] -> assign(assigns, spark_geometry(values, assigns.zero, assigns.invert))
        _short -> assign(assigns, line: nil)
      end

    ~H"""
    <svg :if={@line} viewBox="0 0 200 40" preserveAspectRatio="none" class={["sweep", @class]}>
      <defs>
        <linearGradient id={@gid} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color={@color} stop-opacity="0.32" />
          <stop offset="100%" stop-color={@color} stop-opacity="0" />
        </linearGradient>
      </defs>
      <line
        :if={@zero_y}
        x1="0"
        x2="200"
        y1={@zero_y}
        y2={@zero_y}
        stroke="var(--color-line-bright)"
        stroke-dasharray="3 3"
        vector-effect="non-scaling-stroke"
      />
      <path d={@area} fill={"url(##{@gid})"} />
      <path
        d={@line}
        fill="none"
        stroke={@color}
        stroke-width="2"
        stroke-linejoin="round"
        vector-effect="non-scaling-stroke"
      />
    </svg>
    <div :if={is_nil(@line)} class={@class}></div>
    """
  end

  defp spark_geometry(values, zero?, invert?) do
    {lo, hi} = spark_domain(values, zero?)
    n = length(values) - 1

    y = fn v ->
      t = (v - lo) / (hi - lo)
      4 + if(invert?, do: t, else: 1 - t) * 32
    end

    points = values |> Enum.with_index() |> Enum.map(fn {v, i} -> {i / n * 200, y.(v)} end)
    line = "M" <> Enum.map_join(points, " L", fn {x, y} -> "#{f(x)},#{f(y)}" end)

    [
      line: line,
      area: line <> " L200,40 L0,40 Z",
      zero_y: if(zero?, do: y.(0)),
      gid: "spark-#{System.unique_integer([:positive])}"
    ]
  end

  # Avec `zero`, le domaine inclut toujours zero pour que la ligne pointillee
  # tombe dans le cadre ; un domaine plat est elargi pour eviter une division
  # par zero.
  defp spark_domain(values, zero?) do
    {lo, hi} = Enum.min_max(values)
    {lo, hi} = if zero?, do: {min(lo, 0), max(hi, 0)}, else: {lo, hi}
    if hi == lo, do: {lo - 1, hi + 1}, else: {lo, hi}
  end

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  defp f(value) when is_float(value), do: Float.round(value, 2)
  defp f(value), do: value
end
