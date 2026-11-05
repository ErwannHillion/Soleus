defmodule SoleusWeb.BodyFigure do
  @moduledoc """
  Schema corporel : une silhouette dont chaque region porte l'etat d'un
  systeme physiologique.

  ## Le dessin

  La silhouette est tracee a la main, en proportions humaines usuelles — huit
  tetes de hauteur, largeur d'epaules a environ 1,7 fois la hauteur de tete —
  et decoupee en parties independamment colorables.

  Chaque partie est dessinee **deux fois** : un fond opaque, puis la teinte et
  le contour. Sans le fond opaque, les remplissages translucides se cumulent
  aux recouvrements et laissent voir ce qui passe dessous — le haut des
  cuisses sous le bassin, le cou derriere la machoire. L'ordre de trace va
  donc de l'arriere vers l'avant : jambes, bras, tronc, thorax, tete.

  ## La couleur

  Chaque region prend l'etat le plus degrade des mesures qui s'y rattachent.
  Un seul indicateur hors norme doit se voir, et une moyenne le masquerait.
  Les seuils viennent des lignes de base personnelles de l'athlete partout ou
  elles existent — voir `Soleus.Health.DailyWellness`.
  """

  use Phoenix.Component

  @regions ~w(tete thorax tronc jambes peau)

  # Du plus preoccupant au plus rassurant. Une region prend le premier etat de
  # cette liste qu'une de ses mesures presente.
  @severity [:high, :low, :watch, :in_range, :unknown]

  # Les parties, de l'arriere vers l'avant. La region nomme ce que la partie
  # represente ; plusieurs parties peuvent partager la meme.
  @parts [
    {"jambes",
     "M62 272 C58 308 57 342 59 368 C61 388 64 404 66 420 C67 432 67 442 68 452 " <>
       "C70 472 72 492 73 508 C73 518 72 524 71 528 C70 534 74 538 81 538 C89 538 93 535 93 528 " <>
       "C93 516 94 500 95 484 C96 464 97 444 98 424 C99 400 100 372 100 348 L100 272 Z"},
    {"jambes",
     "M138 272 C142 308 143 342 141 368 C139 388 136 404 134 420 C133 432 133 442 132 452 " <>
       "C130 472 128 492 127 508 C127 518 128 524 129 528 C130 534 126 538 119 538 C111 538 107 535 107 528 " <>
       "C107 516 106 500 105 484 C104 464 103 444 102 424 C101 400 100 372 100 348 L100 272 Z"},
    {"tronc",
     "M52 118 C44 124 39 136 38 150 C36 170 34 192 32 214 C30 236 28 258 27 276 " <>
       "C26 288 24 302 25 314 C25 324 28 331 33 333 C38 335 42 331 42 324 C43 310 44 296 45 282 " <>
       "C47 258 49 234 52 212 C54 190 57 166 60 146 L62 124 Z"},
    {"tronc",
     "M148 118 C156 124 161 136 162 150 C164 170 166 192 168 214 C170 236 172 258 173 276 " <>
       "C174 288 176 302 175 314 C175 324 172 331 167 333 C162 335 158 331 158 324 C157 310 156 296 155 282 " <>
       "C153 258 151 234 148 212 C146 190 143 166 140 146 L138 124 Z"},
    {"tronc",
     "M91 72 L91 88 C77 92 66 97 57 105 C49 113 45 124 44 136 C43 148 44 160 46 172 " <>
       "C49 188 53 204 57 218 C61 231 64 242 65 252 C66 262 66 270 65 278 C64 288 65 296 68 302 " <>
       "C75 311 86 316 100 318 C114 316 125 311 132 302 C135 296 136 288 135 278 C134 270 134 262 135 252 " <>
       "C136 242 139 231 143 218 C147 204 151 188 154 172 C156 160 157 148 156 136 " <>
       "C155 124 151 113 144 106 C134 97 123 92 109 88 L109 72 Z"},
    {"thorax",
     "M78 116 C86 110 93 107 100 107 C107 107 114 110 122 116 C125 128 124 142 120 153 " <>
       "C116 163 109 169 100 170 C91 169 84 163 80 153 C76 142 75 128 78 116 Z"},
    {"tete",
     "M100 12 C113 12 122 20 125 31 C127 39 127 47 126 54 C125 60 123 64 120 67 " <>
       "C118 73 114 80 109 84 C106 87 103 88 100 88 C97 88 94 87 91 84 C86 80 82 73 80 67 " <>
       "C77 64 75 60 74 54 C73 47 73 39 75 31 C78 20 87 12 100 12 Z"}
  ]

  attr :systems, :list, required: true, doc: "sorties de `Soleus.Health.systems/1`"
  attr :class, :string, default: nil

  def body_figure(assigns) do
    assigns =
      assigns
      |> assign(:states, states(assigns.systems))
      |> assign(:parts, @parts)

    ~H"""
    <svg
      viewBox="0 0 200 560"
      class={@class}
      style="aspect-ratio: 200 / 560"
      role="img"
      aria-label="Schema corporel"
    >
      <defs>
        <radialGradient id="body-aura" cx="50%" cy="34%" r="58%">
          <stop offset="0%" stop-color="var(--color-signal)" stop-opacity="0.12" />
          <stop offset="100%" stop-color="var(--color-signal)" stop-opacity="0" />
        </radialGradient>
        <filter id="skin-blur" x="-20%" y="-10%" width="140%" height="120%">
          <feGaussianBlur stdDeviation="7" />
        </filter>
      </defs>

      <rect width="200" height="560" fill="url(#body-aura)" />

      <%!-- La peau : la silhouette entiere, legerement dilatee depuis son
            centre et floutee. Elle enveloppe le corps, ce qui en fait le
            support naturel de la temperature cutanee. --%>
      <g
        filter="url(#skin-blur)"
        opacity="0.13"
        fill={color(@states, "peau")}
        transform="translate(100 285) scale(1.06) translate(-100 -285)"
      >
        <path :for={{_region, d} <- @parts} d={d} />
      </g>

      <%!-- Chaque partie : fond opaque, puis teinte et contour. Voir le
            @moduledoc pour la raison du double trace. --%>
      <g :for={{region, d} <- @parts}>
        <path d={d} fill="var(--color-ink)" />
        <path
          d={d}
          fill={color(@states, region)}
          fill-opacity="0.15"
          stroke={color(@states, region)}
          stroke-width="1.7"
          stroke-linejoin="round"
          stroke-linecap="round"
        />
      </g>
    </svg>
    """
  end

  @doc """
  Couleur d'un etat, utilisable aussi par les listes a cote du schema.

  La meme fonction sert aux deux pour que la pastille d'une mesure et la
  region qu'elle colore ne puissent pas diverger.
  """
  @spec status_color(atom()) :: String.t()
  def status_color(:in_range), do: "var(--color-form)"
  def status_color(:watch), do: "var(--color-fatigue)"
  def status_color(:low), do: "var(--color-alert)"
  def status_color(:high), do: "var(--color-alert)"
  def status_color(_unknown), do: "var(--color-line-bright)"

  @doc "Libelle d'un etat."
  @spec status_label(atom()) :: String.t()
  def status_label(:in_range), do: "dans la normale"
  def status_label(:watch), do: "a surveiller"
  def status_label(:low), do: "sous la normale"
  def status_label(:high), do: "au dessus"
  def status_label(_unknown), do: "non mesure"

  @doc "Les regions du schema."
  def regions, do: @regions

  defp states(systems) do
    Map.new(@regions, fn region ->
      state =
        systems
        |> Enum.filter(&(&1.region == region))
        |> Enum.map(& &1.status)
        |> worst()

      {region, state}
    end)
  end

  defp worst([]), do: :unknown
  defp worst(statuses), do: Enum.find(@severity, :unknown, &(&1 in statuses))

  defp color(states, region), do: states |> Map.get(region, :unknown) |> status_color()
end
