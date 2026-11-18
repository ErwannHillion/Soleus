defmodule SoleusWeb.Dock do
  @moduledoc """
  Barre de navigation flottante en bas d'ecran, a la maniere du dock macOS.

  Le choix du bas plutot que d'une barre laterale ou d'un bandeau superieur est
  dicte par le contenu : un tableau de bord est fait de graphes larges, et la
  largeur est la ressource rare. Une barre laterale en coute cent cinquante
  pixels en permanence, sur toute la hauteur ; le dock n'occupe qu'un ilot
  centre, au dessus duquel le contenu continue de defiler.

  La magnification au survol est une approximation CSS du dock macOS — une
  translation vers le haut et une mise a l'echelle. Le vrai dock deforme aussi
  les icones voisines, ce qui demanderait de suivre la position du curseur en
  JavaScript pour un gain qui ne vaut pas la dependance.
  """

  use Phoenix.Component
  use SoleusWeb, :verified_routes

  @items [
    %{action: :home, path: "/", icon: "hero-squares-2x2", label: "Accueil"},
    %{action: :form, path: "/forme", icon: "hero-bolt", label: "Forme"},
    %{action: :sessions, path: "/seances", icon: "hero-queue-list", label: "Seances"},
    %{action: :curve, path: "/courbe", icon: "hero-presentation-chart-line", label: "Courbe"},
    %{action: :body, path: "/corps", icon: "hero-heart", label: "Corps"},
    %{action: :compare, path: "/compare", icon: "hero-scale", label: "Comparer"},
    %{action: :plan, path: "/plan", icon: "hero-map", label: "Plan"},
    %{action: :predictions, path: "/predictions", icon: "hero-flag", label: "Predictions"}
  ]

  attr :current, :atom, required: true, doc: "l'action LiveView affichee"

  def dock(assigns) do
    assigns = assign(assigns, :items, @items)

    ~H"""
    <nav
      class="pointer-events-none fixed inset-x-0 bottom-0 z-50 flex justify-center pb-5"
      aria-label="Navigation principale"
    >
      <div class="pointer-events-auto flex items-end gap-1 rounded-full border border-line-bright bg-panel/80 p-1.5 shadow-[0_16px_48px_-16px_rgba(0,0,0,0.8)] backdrop-blur-xl">
        <.dock_item :for={item <- @items} item={item} current={@current} />
      </div>
    </nav>
    """
  end

  attr :item, :map, required: true
  attr :current, :atom, required: true

  defp dock_item(assigns) do
    assigns = assign(assigns, :active?, assigns.item.action == assigns.current)

    ~H"""
    <.link
      patch={@item.path}
      aria-current={@active? && "page"}
      class={[
        "group relative flex h-11 w-11 items-center justify-center rounded-full",
        "transition-[transform,background-color] duration-150 ease-out",
        "hover:-translate-y-2 hover:scale-110",
        @active? && "bg-signal",
        !@active? && "hover:bg-panel-raised"
      ]}
    >
      <span class={[
        @item.icon,
        "h-5 w-5",
        if(@active?, do: "bg-ink", else: "bg-dim group-hover:bg-text")
      ]} />

      <%!-- L'infobulle est au dessus de l'icone, et non en dessous : vers le bas
            elle sortirait de l'ecran, le dock etant deja colle au bord. --%>
      <span class="pointer-events-none absolute -top-9 whitespace-nowrap rounded-full border border-line-bright bg-panel px-2.5 py-1 text-[11px] font-semibold text-text opacity-0 transition-opacity duration-150 group-hover:opacity-100">
        {@item.label}
      </span>
    </.link>
    """
  end
end
