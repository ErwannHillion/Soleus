defmodule SoleusWeb.BodyFigure do
  @moduledoc """
  Schema corporel : une silhouette dont chaque region porte l'etat d'un
  systeme physiologique.

  ## Pourquoi une figure stylisee et non anatomique

  La silhouette est composee de formes simples — cercle, capsules — plutot que
  de tracer un corps realiste. Ce n'est pas une facilite : un schema medical
  realiste promettrait une precision que la donnee n'a pas. La montre ne sait
  rien de ses muscles ou de ses organes ; elle mesure un pouls au poignet, un
  mouvement, une temperature cutanee. Une figure franchement schematique dit
  la verite sur ce qu'elle represente, et se lit mieux de loin.

  ## La couleur

  Chaque region prend l'etat le plus degrade des mesures qui s'y rattachent.
  Un seul indicateur hors norme doit se voir, et une moyenne le masquerait.

  Les etats viennent des **lignes de base personnelles** de l'athlete partout
  ou elles existent, jamais de seuils universels — voir
  `Soleus.Health.DailyWellness`.
  """

  use Phoenix.Component

  @regions ~w(tete coeur poumons tronc jambes peau)

  # Du plus preoccupant au plus rassurant. Une region prend le premier etat de
  # cette liste qu'une de ses mesures presente.
  @severity [:high, :low, :watch, :in_range, :unknown]

  attr :systems, :list, required: true, doc: "sorties de `Soleus.Health.systems/1`"
  attr :class, :string, default: nil

  def body_figure(assigns) do
    assigns = assign(assigns, :states, states(assigns.systems))

    ~H"""
    <svg
      viewBox="0 0 220 520"
      class={@class}
      style="aspect-ratio: 220 / 520"
      role="img"
      aria-label="Schema corporel"
    >
      <defs>
        <radialGradient id="body-aura" cx="50%" cy="38%" r="62%">
          <stop offset="0%" stop-color="var(--color-signal)" stop-opacity="0.13" />
          <stop offset="100%" stop-color="var(--color-signal)" stop-opacity="0" />
        </radialGradient>
      </defs>

      <rect width="220" height="520" fill="url(#body-aura)" />

      <%!-- La peau est dessinee en premier et legerement debordante : elle
            forme le halo qui entoure la silhouette, et porte l'etat de la
            temperature cutanee. --%>
      <g opacity="0.14">
        <.silhouette fill={color(@states, "peau")} inflate={8} />
      </g>

      <%!-- Les regions portent leur etat par le **trait**, le remplissage
            restant tres dilue. Un corps entierement dans la normale serait
            sinon une silhouette uniformement vive, qui se lit comme une
            alerte alors que c'est le bon resultat. --%>
      <g>
        <.region shape="head" color={color(@states, "tete")} />
        <.region shape="neck" color={color(@states, "tronc")} />
        <.region shape="chest" color={color(@states, "poumons")} />
        <.region shape="abdomen" color={color(@states, "tronc")} />
        <.region shape="arm_left" color={color(@states, "tronc")} />
        <.region shape="arm_right" color={color(@states, "tronc")} />
        <.region shape="leg_left" color={color(@states, "jambes")} />
        <.region shape="leg_right" color={color(@states, "jambes")} />
      </g>

      <g fill={color(@states, "poumons")} fill-opacity="0.22">
        <path d="M86 112 c-10 4 -14 16 -13 30 l3 26 c1 8 9 10 13 4 l6 -12 z" />
        <path d="M158 112 c10 4 14 16 13 30 l-3 26 c-1 8 -9 10 -13 4 l-6 -12 z" />
      </g>

      <%!-- Le coeur est place a droite du centre vu de l'exterieur, ce qui
            correspond au cote gauche de la personne representee. --%>
      <path
        d="M122 118 c6 -9 20 -8 23 2 c3 10 -6 20 -16 28 c-11 -8 -20 -18 -17 -28 c3 -10 14 -11 10 -2 z"
        fill={color(@states, "coeur")}
        fill-opacity="0.45"
        stroke={color(@states, "coeur")}
        stroke-width="1.4"
      />
    </svg>
    """
  end

  attr :shape, :string, required: true
  attr :color, :string, required: true

  # Geometrie des regions, declaree une seule fois : le halo de peau et les
  # regions colorees dessinent les memes formes, et les laisser diverger
  # ferait apparaitre un contour desaligne au moindre ajustement.
  @shapes [
    {"head", {:circle, 110, 46, 30}},
    {"neck", {:rect, 100, 72, 20, 18, 9}},
    {"chest", {:rect, 64, 88, 92, 98, 28}},
    {"abdomen", {:rect, 74, 176, 72, 92, 24}},
    {"arm_left", {:rect, 34, 98, 22, 152, 11}},
    {"arm_right", {:rect, 164, 98, 22, 152, 11}},
    {"leg_left", {:rect, 78, 262, 28, 206, 14}},
    {"leg_right", {:rect, 114, 262, 28, 206, 14}}
  ]

  defp region(assigns) do
    assigns = assign(assigns, :geometry, @shapes |> List.keyfind(assigns.shape, 0) |> elem(1))

    ~H"""
    <circle
      :if={elem(@geometry, 0) == :circle}
      cx={elem(@geometry, 1)}
      cy={elem(@geometry, 2)}
      r={elem(@geometry, 3)}
      fill={@color}
      fill-opacity="0.15"
      stroke={@color}
      stroke-width="1.6"
    />
    <rect
      :if={elem(@geometry, 0) == :rect}
      x={elem(@geometry, 1)}
      y={elem(@geometry, 2)}
      width={elem(@geometry, 3)}
      height={elem(@geometry, 4)}
      rx={elem(@geometry, 5)}
      fill={@color}
      fill-opacity="0.15"
      stroke={@color}
      stroke-width="1.6"
    />
    """
  end

  attr :fill, :string, required: true
  attr :inflate, :integer, default: 0

  # Le halo de peau : les memes formes, gonflees.
  defp silhouette(assigns) do
    assigns = assign(assigns, :shapes, @shapes)

    ~H"""
    <g fill={@fill}>
      <%= for {_name, geometry} <- @shapes do %>
        <circle
          :if={elem(geometry, 0) == :circle}
          cx={elem(geometry, 1)}
          cy={elem(geometry, 2)}
          r={elem(geometry, 3) + @inflate}
        />
        <rect
          :if={elem(geometry, 0) == :rect}
          x={elem(geometry, 1) - @inflate}
          y={elem(geometry, 2) - @inflate}
          width={elem(geometry, 3) + 2 * @inflate}
          height={elem(geometry, 4) + 2 * @inflate}
          rx={elem(geometry, 5)}
        />
      <% end %>
    </g>
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
