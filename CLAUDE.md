# Soleus

Tableau de bord d'entraînement en course à pied sur données Garmin. Phoenix /
LiveView, Postgres, Oban. Projet **personnel et privé** : un seul athlète, pas
d'authentification.

## Règles

Lire les fichiers de `.claude/rules/` avant de travailler. Les plus
structurants :

| Fichier | Contenu |
|---|---|
| `project-specific.md` | architecture, les trois échelles de temps du moteur, pièges connus |
| `elixir-code.md` | pas d'assertion par match sur une donnée d'entrée |
| `configuration.md` | `System.get_env` uniquement dans `config/*.exs`, lecture par `Soleus.Config` |
| `database.md` | migrations, upserts, spécificités du schéma |
| `git-commits.md` | nomenclature `type(scope)`, identité personnelle, aucune mention d'IA |
| `chrome-headless.md` | nettoyer les Chrome headless et le port 4006 |
| `changelog.md` | `CHANGELOG.md` sous `[Unreleased]` |
| `pull-requests.md` | format des PR |

## Commandes

```sh
docker compose up -d db     # Postgres 17 sur 5436
mix ecto.setup
mix phx.server              # http://localhost:4006

mix soleus.rebuild          # recalcule métriques, charge, modèles
mix run priv/repo/seeds_demo.exs   # six mois d'historique de démonstration

mix format
mix credo --strict          # doit être vert, les dix checks de .credo/ sont branchés
mix test
```

## Avant de rendre la main

1. `mix format`
2. `mix credo --strict` — vert
3. `mix test`
4. `CHANGELOG.md` à jour sous `[Unreleased]`
5. Pas de Chrome headless ni de serveur de dev laissé derrière
   (`./scripts/kill-headless-chrome.sh`, `lsof -nP -iTCP:4006 -sTCP:LISTEN`)

## À savoir avant de toucher au moteur

Le générateur de démonstration n'est pas qu'un jeu de données : il construit
les séances à partir d'une vitesse critique qui progresse lentement, et
l'ajustement doit la retrouver. **Si la vitesse critique ajustée ne ressemble
pas à celle injectée, c'est le moteur qui a tort**, pas le générateur.

```sh
mix ecto.reset && mix run priv/repo/seeds_demo.exs && mix soleus.rebuild
```

La valeur injectée en fin de période est `cs_end` dans
`priv/repo/seeds_demo.exs`.
