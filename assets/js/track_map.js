import * as L from "../vendor/leaflet.js";

// Carte du trace GPS d'une seance, sur fond OpenStreetMap.
//
// Leaflet et sa feuille de style sont servis depuis `assets/vendor` et non
// depuis un CDN : l'application tourne en local, et dependre d'un hote
// exterieur pour afficher une carte la rendrait inutilisable hors ligne pour
// la partie qui, justement, marche sans reseau — le reste du tableau de bord.
//
// Les tuiles, elles, viennent bien d'OpenStreetMap. L'attribution est donc
// obligatoire, et Leaflet l'affiche a partir de l'option `attribution`.
export const TrackMap = {
  mounted() {
    this.render();

    // Le curseur suit le survol des graphiques de la meme seance. Garde une
    // reference pour pouvoir se desabonner : sans cela, naviguer d'une seance
    // a l'autre empilerait un ecouteur par visite.
    this.onScrub = (event) => this.scrub(event.detail.t);
    document.addEventListener("soleus:scrub", this.onScrub);
  },

  updated() {
    // Le conteneur a pu etre remplace par LiveView : on repart d'une carte
    // neuve plutot que de tenter de recoller l'ancienne a un noeud disparu.
    this.destroy();
    this.render();
  },

  destroyed() {
    document.removeEventListener("soleus:scrub", this.onScrub);
    this.destroy();
  },

  destroy() {
    if (this.map) {
      this.map.remove();
      this.map = null;
      this.cursor = null;
    }
  },

  // Positionne le curseur a l'instant demande. La recherche est lineaire sur
  // quelques centaines de points : une dichotomie ne se justifierait pas pour
  // un gain imperceptible sur un evenement de souris.
  scrub(t) {
    if (!this.map || !this.points) return;

    if (t == null) {
      if (this.cursor) this.cursor.setStyle({ opacity: 0, fillOpacity: 0 });
      return;
    }

    let best = null;
    let distance = Infinity;

    for (const point of this.points) {
      const gap = Math.abs(point[2] - t);
      if (gap < distance) {
        distance = gap;
        best = point;
      }
    }

    if (!best) return;

    if (!this.cursor) {
      this.cursor = L.circleMarker([best[0], best[1]], {
        radius: 6,
        color: "#f3f5f9",
        fillColor: "#c6f432",
        fillOpacity: 1,
        weight: 2,
      }).addTo(this.map);
    } else {
      this.cursor.setLatLng([best[0], best[1]]);
      this.cursor.setStyle({ opacity: 1, fillOpacity: 1 });
    }
  },

  render() {
    const points = this.readPoints();
    this.points = points;
    if (points.length < 2) return;

    this.map = L.map(this.el, {
      zoomControl: true,
      attributionControl: true,
      // La carte est une illustration, pas un outil de navigation : on la
      // laisse se deplacer mais sans defilement a la molette, qui capturerait
      // le scroll de la page a chaque passage de souris.
      scrollWheelZoom: false,
    });

    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 18,
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
    }).addTo(this.map);

    const line = L.polyline(points, {
      color: "#c6f432",
      weight: 3,
      opacity: 0.95,
      lineJoin: "round",
      lineCap: "round",
    }).addTo(this.map);

    L.circleMarker(points[0], {
      radius: 5,
      color: "#36d6f0",
      fillColor: "#36d6f0",
      fillOpacity: 1,
      weight: 2,
    })
      .addTo(this.map)
      .bindTooltip("Depart");

    L.circleMarker(points[points.length - 1], {
      radius: 5,
      color: "#ff5272",
      fillColor: "#12151b",
      fillOpacity: 1,
      weight: 2,
    })
      .addTo(this.map)
      .bindTooltip("Arrivee");

    this.map.fitBounds(line.getBounds(), { padding: [18, 18] });
  },

  readPoints() {
    try {
      return JSON.parse(this.el.dataset.track || "[]");
    } catch {
      return [];
    }
  },
};
