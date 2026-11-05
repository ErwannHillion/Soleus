// Selection d'une plage de dates par glisser sur un graphique.
//
// C'est le seul JavaScript de Soleus, et il est volontairement reduit a ce
// que le serveur ne peut pas faire : suivre un pointeur. Le hook ne dessine
// rien d'autre que le rectangle de selection en cours ; des que le bouton est
// relache, il envoie deux dates a LiveView et laisse le serveur redessiner.
//
// Les coordonnees sont converties en dates par le hook plutot que renvoyees
// en pixels, pour que le serveur n'ait pas a connaitre la geometrie du SVG.
export const Brush = {
  mounted() {
    this.from = new Date(this.el.dataset.from);
    this.to = new Date(this.el.dataset.to);
    this.overlay = this.el.querySelector("[data-brush-overlay]");
    this.start = null;

    this.el.addEventListener("pointerdown", (event) => this.begin(event));
    this.el.addEventListener("pointermove", (event) => this.extend(event));
    this.el.addEventListener("pointerup", (event) => this.finish(event));
    this.el.addEventListener("pointercancel", () => this.cancel());
  },

  updated() {
    // Les bornes changent quand le serveur redessine : sans cette reprise, un
    // second glisser calculerait ses dates sur l'ancienne plage.
    this.from = new Date(this.el.dataset.from);
    this.to = new Date(this.el.dataset.to);
    this.overlay = this.el.querySelector("[data-brush-overlay]");
    this.cancel();
  },

  ratio(event) {
    const box = this.el.getBoundingClientRect();
    if (box.width === 0) return 0;
    return Math.min(1, Math.max(0, (event.clientX - box.left) / box.width));
  },

  begin(event) {
    this.start = this.ratio(event);
    this.el.setPointerCapture(event.pointerId);
    this.paint(this.start, this.start);
  },

  extend(event) {
    if (this.start === null) return;
    this.paint(this.start, this.ratio(event));
  },

  finish(event) {
    if (this.start === null) return;
    const end = this.ratio(event);
    const [low, high] = [this.start, end].sort((a, b) => a - b);
    this.cancel();

    // Un simple clic ne doit pas reduire la periode a un seul jour. En deca
    // de 2 % de la largeur, on considere que c'est un clic et non un glisser.
    if (high - low < 0.02) return;

    this.pushEvent("select_range", {
      from: this.dateAt(low),
      to: this.dateAt(high),
    });
  },

  cancel() {
    this.start = null;
    if (this.overlay) this.overlay.style.display = "none";
  },

  paint(a, b) {
    if (!this.overlay) return;
    const [low, high] = [a, b].sort((x, y) => x - y);
    this.overlay.style.display = "block";
    this.overlay.style.left = `${low * 100}%`;
    this.overlay.style.width = `${(high - low) * 100}%`;
  },

  dateAt(ratio) {
    const span = this.to.getTime() - this.from.getTime();
    const at = new Date(this.from.getTime() + span * ratio);
    return at.toISOString().slice(0, 10);
  },
};
