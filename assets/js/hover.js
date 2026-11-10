// Lecture au survol d'un graphique.
//
// Les points sont envoyes une fois dans `data-hover`, au rendu, et le survol
// se resout entierement cote client. Un aller-retour LiveView par mouvement
// de souris serait inutilisable : a soixante images par seconde, c'est une
// requete toutes les seize millisecondes pour afficher une valeur qui est
// deja connue au moment du rendu.
//
// Le hook ne calcule donc aucune donnee. Il choisit le point le plus proche
// du curseur et affiche ce que le serveur a deja formate.
export const Hover = {
  mounted() {
    this.read();
    this.line = this.el.querySelector("[data-hover-line]");
    this.card = this.el.querySelector("[data-hover-card]");

    this.el.addEventListener("pointermove", (event) => this.show(event));
    this.el.addEventListener("pointerleave", () => this.hide());
  },

  updated() {
    this.read();
    this.line = this.el.querySelector("[data-hover-line]");
    this.card = this.el.querySelector("[data-hover-card]");
    this.hide();
  },

  read() {
    try {
      this.points = JSON.parse(this.el.dataset.hover || "[]");
    } catch {
      this.points = [];
    }
  },

  // Recherche lineaire : les graphes portent au plus quelques centaines de
  // points, et une dichotomie ne se justifierait pas pour un gain
  // imperceptible sur un evenement de souris.
  nearest(ratio) {
    let best = null;
    let distance = Infinity;

    for (const point of this.points) {
      const gap = Math.abs(point.x - ratio);
      if (gap < distance) {
        distance = gap;
        best = point;
      }
    }

    return best;
  },

  show(event) {
    if (!this.points.length || !this.card || !this.line) return;

    const box = this.el.getBoundingClientRect();
    if (box.width === 0) return;

    const ratio = ((event.clientX - box.left) / box.width) * 100;
    const point = this.nearest(ratio);
    if (!point) return;

    this.line.style.display = "block";
    this.line.style.left = `${point.x}%`;

    this.card.innerHTML = this.render(point);
    this.card.style.display = "block";

    // Les autres composants de la page — la carte, notamment — ecoutent cet
    // evenement pour se positionner au meme instant. Passer par le document
    // plutot que par LiveView evite un aller-retour serveur a chaque pixel
    // parcouru, et laisse chaque composant libre de l'ignorer.
    if (point.t != null) {
      document.dispatchEvent(
        new CustomEvent("soleus:scrub", { detail: { t: point.t } }),
      );
    }

    // La carte bascule du cote oppose passe la moitie du graphe, pour ne
    // jamais sortir du cadre sur les derniers points.
    const flip = point.x > 55;
    this.card.style.left = flip ? "auto" : `calc(${point.x}% + 10px)`;
    this.card.style.right = flip ? `calc(${100 - point.x}% + 10px)` : "auto";
  },

  hide() {
    if (this.line) this.line.style.display = "none";
    if (this.card) this.card.style.display = "none";
    document.dispatchEvent(new CustomEvent("soleus:scrub", { detail: { t: null } }));
  },

  render(point) {
    const rows = (point.rows || [])
      .map(
        (row) =>
          `<div class="flex items-baseline justify-between gap-4">
             <span class="flex items-center gap-1.5">
               <span class="h-0.5 w-2.5" style="background:${row.c}"></span>
               <span class="text-[10px] text-dim">${escape(row.k)}</span>
             </span>
             <span class="num text-[11px] text-text">${escape(row.v)}</span>
           </div>`,
      )
      .join("");

    return `<div class="num mb-1.5 text-[10px] uppercase tracking-[0.08em] text-faint">${escape(
      point.label,
    )}</div>${rows}`;
  },
};

// Les libelles viennent du serveur, mais ils contiennent des noms de seance
// saisis par l'utilisateur dans Garmin. Les echapper evite qu'un nom portant
// un chevron casse la carte.
function escape(value) {
  return String(value ?? "").replace(
    /[&<>"']/g,
    (char) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char],
  );
}
