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
  },

  updated() {
    // Le conteneur a pu etre remplace par LiveView : on repart d'une carte
    // neuve plutot que de tenter de recoller l'ancienne a un noeud disparu.
    this.destroy();
    this.render();
  },

  destroyed() {
    this.destroy();
  },

  destroy() {
    if (this.map) {
      this.map.remove();
      this.map = null;
    }
  },

  render() {
    const points = this.points();
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
      color: "#7c5cff",
      weight: 3,
      opacity: 0.95,
      lineJoin: "round",
      lineCap: "round",
    }).addTo(this.map);

    L.circleMarker(points[0], {
      radius: 5,
      color: "#35e0a1",
      fillColor: "#35e0a1",
      fillOpacity: 1,
      weight: 2,
    })
      .addTo(this.map)
      .bindTooltip("Depart");

    L.circleMarker(points[points.length - 1], {
      radius: 5,
      color: "#ff5470",
      fillColor: "#07070a",
      fillOpacity: 1,
      weight: 2,
    })
      .addTo(this.map)
      .bindTooltip("Arrivee");

    this.map.fitBounds(line.getBounds(), { padding: [18, 18] });
  },

  points() {
    try {
      return JSON.parse(this.el.dataset.track || "[]");
    } catch {
      return [];
    }
  },
};
