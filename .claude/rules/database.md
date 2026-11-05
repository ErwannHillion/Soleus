# Database Rules

## Migrations

### Création de Migrations

**TOUJOURS utiliser `mix ecto.gen.migration`** pour créer les migrations.

```bash
# ✅ Bon
mix ecto.gen.migration add_status_to_users

# ❌ Mauvais - Créer le fichier manuellement
touch priv/repo/migrations/20250121_add_status.exs
```

**Raison** : `mix ecto.gen.migration` génère le timestamp correct et la structure de base.

### Environnement de Développement

✅ **Autorisé en DEV** :
- Créer des migrations via `mix ecto.gen.migration`
- Modifier des migrations non encore mergées
- `mix ecto.reset` si nécessaire
- Expérimenter avec la structure

### Bonnes Pratiques

✅ **Toujours** :
- Utiliser `mix ecto.gen.migration` pour créer
- Nommer les migrations de manière descriptive
- Tester les migrations localement avant commit
- Prévoir un rollback (`down` function)
- Utiliser des transactions pour les migrations complexes

❌ **Éviter** :
- Modifier une migration déjà mergée en production
- Supprimer des colonnes sans plan de migration
- Changer le type d'une colonne peuplée sans gestion des données existantes

### Modifier des Données Existantes

⚠️ **TOUJOURS demander** avant de créer une migration :
- "Veux-tu que je modifie aussi les données existantes ?"
- "Ou juste le schema ?"

Ne JAMAIS supposer. Toujours clarifier.

### Exemples

```elixir
# ✅ Migration sûre
def change do
  alter table(:users) do
    add :phone, :string
    add :verified, :boolean, default: false
  end
end

# ⚠️ Migration qui modifie des données - DEMANDER CONFIRMATION
def up do
  alter table(:users) do
    add :status, :string, default: "active"
  end

  # Mise à jour des données existantes
  execute "UPDATE users SET status = 'active' WHERE status IS NULL"
end

def down do
  alter table(:users) do
    remove :status
  end
end
```

## Requêtes Ecto

### Upserts (Insert or Update)

**TOUJOURS préférer** les upserts avec `on_conflict` plutôt que retrieve-then-insert.

```elixir
# ✅ Bon - Upsert idempotent
def upsert_fit(date, attrs) do
  %ModelFit{}
  |> ModelFit.changeset(attrs)
  |> Repo.insert(
    on_conflict: {:replace, @fit_columns},
    conflict_target: [:fitted_on, :sport, :window_days]
  )
end

# ❌ Éviter - Retrieve puis insert
def upsert_user(email, attrs) do
  case Repo.get_by(User, email: email) do
    nil -> Repo.insert(%User{email: email} |> User.changeset(attrs))
    user -> Repo.update(User.changeset(user, attrs))
  end
end
```

**Raison** : Upserts sont atomiques, évitent les race conditions, et plus performants.

### Performance

- Toujours précharger les associations nécessaires
- Utiliser `select` pour limiter les colonnes
- Paginer ou borner les listes (`limit`)
- Indexer les colonnes fréquemment recherchées

### Exemple

```elixir
# ✅ Bon - Précharge les associations
Repo.all(
  from u in User,
  where: u.active == true,
  preload: [:profile, :organization]
)

# ❌ Éviter - N+1 queries
users = Repo.all(User)
Enum.map(users, fn u -> u.profile end)
```

## Seeds

- Idempotent : peut être exécuté plusieurs fois
- Ne jamais supprimer de données existantes
- **Préférer upserts** avec `on_conflict`

```elixir
# ✅ Idempotent avec upsert
%User{email: "admin@example.com"}
|> User.changeset(%{name: "Admin", role: :admin})
|> Repo.insert(
  on_conflict: :nothing,
  conflict_target: :email
)

# ❌ Éviter - Non idempotent
Repo.insert!(%User{email: "admin@example.com", name: "Admin"})
```

## Inspecter la base

Pas de MCP Tidewave sur ce projet. Utiliser IEx ou `mix run -e`, pas `psql` :
le code Elixir passe par les schémas, donc les types et les associations sont
respectés.

```elixir
# ✅ Bon
iex> Soleus.Analytics.current_fit()
iex> Soleus.Training.personal_bests("run") |> Enum.take(3)
iex> Soleus.Repo.aggregate(Soleus.Training.Activity, :count)

# ❌ Éviter
$ psql -p 5436 -d soleus_dev -c "SELECT COUNT(*) FROM activities;"
```

## Spécificités de ce schéma

### `activity_streams` : un blob, pas des lignes

Les séries point par point sont **un seul terme Erlang compressé** par séance.
Ne pas « normaliser » : ce serait une table à dizaines de millions de lignes
pour une donnée toujours lue en entier. Voir
`.claude/rules/project-specific.md`.

### `daily_loads` : matérialisé et reconstruit en entier

Les colonnes `ctl`, `atl`, `tsb` sont des moyennes exponentielles : chaque jour
dépend du précédent. Elles sont stockées, et `Analytics.rebuild_daily_loads/0`
recalcule **toute** la série, jamais un sous-ensemble.

### `athlete` : table à ligne unique

Contrainte `CHECK (id = 1)`. Soleus est une application personnelle. Ne pas y
ajouter de notion d'utilisateur sans raison explicite.

### Idempotence de l'ingestion

`activities.fit_digest` (SHA-256 du fichier) et `(source, external_id)` portent
des index uniques partiels. Réimporter un export ne crée pas de doublon, et
`Training.import_fit/2` rend `{:ok, :already_imported, activity}` — pas une
erreur : repasser sur un dossier est un geste normal.
