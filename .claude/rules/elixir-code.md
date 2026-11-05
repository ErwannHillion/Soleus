# Conventions de Code Elixir

## Autorisation : jamais d'assertion par match

**INTERDIT** : utiliser `true = expr` (ou tout match assertif) pour vérifier une
autorisation ou valider une donnée issue de l'utilisateur.

```elixir
# ❌ Mauvais - assertion par match
def link_prompt_to_deal(%Scope{} = scope, %Prompt{} = prompt, %Deal{} = deal) do
  true = prompt.user_id == scope.user.id
  true = deal.user_id == scope.user.id
  # ...
end
```

### Pourquoi

Un accès refusé est un cas de fonctionnement **normal**, pas un bug. Le traiter par
un crash relève de l'anti-pattern officiel « Exceptions for control-flow ».

Concrètement :

- `** (MatchError) no match of right hand side value: false` — on ignore quelle
  vérification a échoué, pour quel utilisateur, sur quelle ressource.
- L'appelant n'a aucune valeur à filtrer. Il devrait `rescue MatchError`, ce qui
  attraperait aussi les `MatchError` sans rapport venus d'ailleurs dans la pile.
- `MatchError` n'implémente pas `Plug.Exception` : en Phoenix la requête sort en
  **500, pas en 403**, et pollue le suivi d'erreurs.

### À la place

Filtrer dans la tête de fonction. Une variable répétée impose l'égalité au moment
du match ; une seconde clause transforme l'échec en valeur.

```elixir
# ✅ Bon - filtrage dans la signature
def link_prompt_to_deal(
      %Scope{user: %{id: user_id}},
      %Prompt{user_id: user_id} = prompt,
      %Deal{user_id: user_id} = deal
    ) do
  # autorisé par construction
end

def link_prompt_to_deal(%Scope{}, %Prompt{}, %Deal{}) do
  {:error, :unauthorized}
end
```

### La clause de repli reste assertive

Elle doit matcher les structs attendues (`%Scope{}, %Prompt{}, %Deal{}`), **jamais
`_, _, _`**.

```elixir
# ❌ Mauvais - avale aussi les appels mal typés
def link_prompt_to_deal(_, _, _), do: {:error, :unauthorized}
```

Un repli trop large transforme un crash utile — un appel avec les mauvais types,
qui est bien un bug — en `{:error, :unauthorized}` trompeur.

### Raisons d'échec distinctes

Quand l'appelant doit savoir *pourquoi* c'est refusé, utiliser `with` sur des
fonctions renvoyant `:ok | {:error, raison}`.

```elixir
# ✅ Bon - chaque échec porte sa raison
with :ok <- authorize_prompt(scope, prompt),
     :ok <- authorize_deal(scope, deal) do
  # ...
end
```

### Seule exception tolérée

Un invariant réellement impossible, indépendant de l'entrée utilisateur — une
donnée que la fonction a elle-même construite. Même là, préférer une garde ou un
`raise` porteur d'un message explicite.

### Détection

Le check `.credo/no_true_match.ex` **est branché** sur ce projet : `.credo.exs`
existe à la racine et charge les dix checks maison par `requires: [".credo/"]`.

```bash
mix credo --strict    # doit être vert, sans exception
```

Vérification manuelle complémentaire :

```bash
git grep -n "true = " -- 'lib/**/*.ex'
```

### État du code

Aucune occurrence. Le projet est parti propre sur ce point — ne pas en
introduire.

Note : Soleus n'a ni authentification ni autorisation (projet personnel,
un seul athlète). La règle garde tout son sens pour la **validation de donnée
d'entrée** : un fichier FIT corrompu, une série sans horodatage, une clé d'API
expirée sont des cas de fonctionnement normal et doivent rendre
`{:error, raison}`, pas lever.

```elixir
# ✅ Un fichier illisible au milieu d'un lot de mille ne doit pas
#    interrompre l'import
@spec decode(Path.t()) :: {:ok, decoded()} | {:error, term()}
def decode(path) do
  with {:ok, raw} <- File.read(path),
       {:ok, records} <- FitFile.from_binary(raw) do
    build(records, digest(raw))
  else
    {:error, reason} -> {:error, reason}
    other -> {:error, {:unexpected_parser_result, other}}
  end
end
```
