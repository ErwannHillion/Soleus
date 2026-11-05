# Chrome headless : nettoyer avant de rendre la main

## La règle

**Toute session qui lance un Chrome headless le referme avant de terminer.**

```bash
ps -axo comm= | grep -ci "google chrome"   # combien tournent
./scripts/kill-headless-chrome.sh          # les fermer
```

## Pourquoi sur ce projet

Soleus n'embarque pas ChromicPDF ni Wallaby. Le Chrome headless n'arrive ici
que par une capture d'écran du tableau de bord pendant le développement :

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless --disable-gpu --hide-scrollbars \
  --window-size=1680,1200 \
  --screenshot=/tmp/soleus.png http://localhost:4006/
```

Chaque appel laisse plusieurs processus derrière lui. Sur une session de
travail qui itère sur le design, ça se compte en dizaines.

## Le piège du filtre

Le navigateur interactif et le headless partagent le même binaire. Un
`pkill -f "Google Chrome"` emporterait les onglets de l'utilisateur.

❌ `pkill -f "Google Chrome"`
❌ `pgrep -fa` — tronque les lignes de commande, le comptage est faux
❌ `ps ... | grep -- '--headless'` — attrape sa propre ligne de commande

✅ Filtrer sur le binaire **et** sur le drapeau :

```bash
ps -axo pid=,args= | awk '/Google Chrome\.app/ && /--headless/ {print $1}'
```

## Le serveur de développement aussi

Même règle pour `mix phx.server` lancé en arrière-plan : le port `4006` doit
être libre à la fin de la session.

```bash
lsof -nP -iTCP:4006 -sTCP:LISTEN
```

Un `mix run` ou un `mix soleus.rebuild` démarre aussi l'application, donc
l'`Endpoint` : deux de ces commandes en parallèle se disputent le port et la
seconde échoue sur `:eaddrinuse`.
