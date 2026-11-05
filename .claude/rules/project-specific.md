# Soleus — Règles spécifiques au projet

## Ce qu'est le projet

Tableau de bord d'entraînement en course à pied, sur données Garmin. Projet
**personnel et privé**, un seul athlète, pas d'authentification, pas de
multi-tenant. Les choix d'architecture en découlent : une table `athlete` à
ligne unique, pas de `scope`, pas de permissions.

## Architecture

### Contextes

| Contexte | Rôle | Dépend de |
|---|---|---|
| `Soleus.Training` | séances, séries, efforts records, athlète | — |
| `Soleus.Ingest.Fit` | décodage des fichiers FIT | — |
| `Soleus.Analytics` | métriques, charge, modèles, projections | `Training` |
| `Soleus.Config` | accès unique à la configuration | — |
| `Soleus.Workers.*` | jobs Oban d'ingestion et d'analyse | les deux |

**`Analytics` dépend de `Training`, jamais l'inverse.** `Training` stocke le
résultat des métriques mais n'en calcule aucune.

### Les trois échelles de temps du moteur

Tout le moteur se lit sur cet axe, et chaque niveau dépend du précédent :

1. **par séance** — charge, TRIMP, facteur d'intensité, découplage aérobie.
   Dépend du fichier seul.
2. **par jour** — modèle de Banister (CTL, ATL, forme). Dépend de la veille,
   donc se déroule en série et se **matérialise**.
3. **par période** — vitesse critique, exposant d'endurance, VDOT. Dépend
   d'une fenêtre glissante de 90 jours d'efforts records.

La projection de progression se lit au-dessus du niveau 3 : c'est la pente de
la vitesse critique dans le temps.

### Modules de modèle

- `Analytics.MeanMaximal` — courbe vitesse-durée, grille à 1 Hz
- `Analytics.CriticalSpeed` — modèle à deux paramètres (CS, D′)
- `Analytics.Endurance` — loi de puissance, Riegel personnalisé
- `Analytics.Vdot` — Daniels–Gilbert
- `Analytics.Load` — TRIMP, rTSS, Banister
- `Analytics.Decoupling` — dérive cardiaque (Pa:HR)
- `Analytics.Regression` — moindres carrés, en Elixir pur

## Pièges connus

### Les séries sont un blob, pas des lignes

`Training.Stream` stocke toutes les séries d'une séance dans **un seul terme
Erlang compressé**. Ne pas « normaliser » en une ligne par échantillon : ce
serait une table à dizaines de millions de lignes pour une donnée toujours lue
en entier.

Les clés autorisées sont déclarées dans `@series_keys` de `Training.Stream`, et
**pas ailleurs**. Ce n'est pas de la documentation : `binary_to_term/2` en mode
`:safe` refuse les atomes qui n'existent pas encore dans la VM. Une clé nommée
uniquement dans le décodeur FIT rendrait le décodage dépendant de l'ordre de
chargement des modules. Un check à la compilation dans `Ingest.Fit` garde les
deux listes alignées.

### La série de charge se reconstruit en entier

`Analytics.rebuild_daily_loads/0` recalcule depuis la première activité, jamais
en place. Les moyennes exponentielles se propagent : importer une séance d'il y
a trois mois invalide tout ce qui suit.

Les jours de repos **doivent** figurer avec une charge nulle, sinon la fatigue
aiguë ne redescend jamais.

### Les prédictions longues ne passent pas par la loi de puissance ajustée

Une courbe de meilleurs efforts tirée de l'entraînement n'est maximale que là
où l'athlète a réellement couru fort. Les paliers de 2 à 20 minutes sont
couverts par le fractionné ; ceux d'une heure ne le sont que par les sorties
longues, courues en footing. Ajuster un exposant d'endurance là-dessus mesure
la lenteur des footings.

`Analytics.predictions/3` confronte donc les deux modèles à 20 minutes et ne
retient l'exposant personnel que s'ils concordent. Sinon il retombe sur le 1.06
de Riegel, et `exponent_source` vaut `"literature"`.

### Projection et prédictions doivent utiliser la même cascade

`Analytics.project/3` appelle `predict_distance/4`, et son jour 0 est ancré sur
`latest.cs_ms`. Les faire diverger produit deux chiffres contradictoires sur la
même ligne de l'écran.

### `mix soleus.rebuild` : ne pas sauter l'étape 3

Les ajustements historiques (un par jour) sont ce qui donne à la projection une
pente à extrapoler. Sans eux il n'existe qu'un ajustement, celui d'aujourd'hui.

## Sources de données

| Source | Contenu | Limites |
|---|---|---|
| Export RGPD Garmin | tout l'historique en `.fit` | manuel, une fois |
| Garmin Personal API | activités, `.fit`, sommeil, HRV | clé expirable, token 24 h sans rafraîchissement, backfill ~30 j, pas de webhook |
| API Strava | flux 1 Hz, webhook | données retravaillées, ni HRV ni Running Dynamics |

Stratégie retenue : RGPD pour amorcer, Personal API pour l'incrémental.

## Interface

- **Sombre uniquement.** Pas de bascule de thème : c'est un instrument de
  mesure, pas un site.
- Le **violet est une couleur de signal**, pas un fond. Il marque la donnée
  principale et rien d'autre.
- Tous les chiffres portent la classe `.num` (chasse fixe, `tabular-nums`).
- Les séparations sont des **filets d'un pixel**, jamais des ombres.
- Les graphes sont du **SVG généré en Elixir** (`SoleusWeb.Charts`). La limite
  est connue : au-delà de quelques milliers de points — les séries seconde par
  seconde — il faudra un `canvas` piloté par un hook.

## Variables d'environnement

Toutes optionnelles : l'application démarre et importe des fichiers FIT sans
aucune.

| Variable | Défaut | Rôle |
|---|---|---|
| `POSTGRES_PORT` | `5436` | port du conteneur Postgres |
| `GARMIN_API_KEY` | — | clé personnelle Garmin Connect |

Les ports sont volontairement non standards (Postgres `5436`, serveur `4006`) :
plusieurs projets coexistent sur la machine de développement.

## Outils

Pas de MCP Tidewave sur ce projet. Pour inspecter la base, utiliser `iex -S mix`
ou `mix run -e`, pas `psql` :

```elixir
iex> Soleus.Analytics.current_fit()
iex> Soleus.Training.personal_bests("run") |> Enum.take(3)
```
