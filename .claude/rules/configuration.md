# Configuration

## La règle

**`System.get_env` ne vit que dans `config/*.exs`. Le code applicatif lit la
configuration par `Soleus.Config`.**

Le check `.credo/no_direct_application_get_env.ex` l'impose : seuls
`lib/soleus/config.ex` et `lib/soleus/application.ex` peuvent appeler
`Application.get_env(:soleus, ...)`.

```elixir
# ❌ Mauvais — variable d'environnement lue dans le code
defmodule Soleus.Ingest.GarminApi do
  def key, do: System.get_env("GARMIN_API_KEY")
end

# ❌ Mauvais — accès direct à la config applicative
defmodule Soleus.Ingest.GarminApi do
  def key, do: Application.get_env(:soleus, :garmin_api_key)
end

# ✅ Bon
defmodule Soleus.Ingest.GarminApi do
  def key, do: Soleus.Config.garmin_api_key()
end
```

### Pourquoi

Ce n'est pas du dogme, c'est pratique. Une clé lue à six endroits n'a nulle
part de valeur par défaut unique, et chaque appelant finit par en inventer une
légèrement différente. Dans `Soleus.Config`, chaque réglage a un nom de
fonction, un type de retour et un défaut, en un seul endroit.

Et `System.get_env` dans le code est lu **à l'exécution** : en release, les
variables ne sont pas forcément présentes dans l'environnement du processus au
moment de l'appel. La configuration se lit au démarrage, pas à l'usage.

## Ajouter un réglage

Trois endroits, dans cet ordre :

1. **`config/runtime.exs`** — la lecture de l'environnement, avec un défaut

   ```elixir
   config :soleus, garmin_api_key: System.get_env("GARMIN_API_KEY")
   ```

2. **`lib/soleus/config.ex`** — l'accesseur, avec son `@doc` et son `@spec`

   ```elixir
   @doc """
   Clé d'API personnelle Garmin Connect.

   Rend `nil` quand elle n'est pas configurée, ce qui est l'état normal avant
   la première mise en place : l'import de fichiers FIT fonctionne sans.
   """
   @spec garmin_api_key() :: String.t() | nil
   def garmin_api_key, do: get(:garmin_api_key)
   ```

3. **`README.md` et `.claude/rules/project-specific.md`** — le tableau des
   variables d'environnement

## Défauts

**Toute variable optionnelle a un défaut qui permet de démarrer.** Soleus doit
pouvoir tourner et importer des fichiers FIT sans aucune variable définie :
c'est l'état d'un nouveau poste, et aussi celui de la CI.

```elixir
# ✅ Un défaut utilisable
def fit_import_dir, do: get(:fit_import_dir, Path.join(:code.priv_dir(:soleus), "import"))

# ❌ Pas de défaut sur un réglage qui conditionne le démarrage
def fit_import_dir, do: get(:fit_import_dir) || raise "manquant"
```

Une clé réellement obligatoire se vérifie dans `config/runtime.exs`, au
démarrage, avec un message qui dit quoi faire — pas au premier appel.

## Ports

Volontairement non standards, pour cohabiter avec les autres projets de la
machine :

| Service | Port | Défini dans |
|---|---|---|
| Postgres (dev et test) | `5436` | `docker-compose.yml`, `config/dev.exs`, `config/test.exs` |
| Serveur de développement | `4006` | `config/dev.exs` |
| Serveur de test | `4007` | `config/test.exs` |

Le port Postgres est surchargeable par `POSTGRES_PORT`, et `docker-compose.yml`
lit la même variable : le conteneur et l'application ne peuvent pas se
contredire.

## Secrets

- `.env` est dans `.gitignore`
- aucune clé en clair dans `config/*.exs`
- la clé Garmin est personnelle et expire (30 à 365 jours) : prévoir qu'elle
  soit absente ou périmée, et le dire dans l'interface plutôt que de planter
