# Environnements Dev / Prod — Aegis AI Infra

> ⚠️ **Ne jamais modifier, commit ou push le dépôt depuis leCube5080. Toute
> modification doit être créée et validée sur un poste de développement,
> puis déployée en production par ArgoCD.**

---

## 1. Architecture

```
kubernetes/
├── bootstrap/
│   ├── root-app-mvp.yaml   # App ArgoCD racine actuellement live sur leCube5080
│   ├── root-app-prod.yaml  # Même Application (nom identique), path -> envs/prod
│   └── root-app-dev.yaml   # App racine optionnelle pour tester ArgoCD en local
├── envs/
│   ├── mvp/   # État actuellement déployé. Conservé temporairement (voir §8).
│   ├── prod/  # Overlay Kustomize de envs/mvp : mêmes noms, 2 correctifs.
│   └── dev/
│       ├── dev-core/  # Profil par défaut : Postgres, Redis, api-gateway, brain, dashboard
│       └── dev-full/  # dev-core + Temporal, MinIO, Neo4j, ClickHouse, KEDA, workers
├── charts/aegis-service/  # Chart Helm générique, réutilisé par mvp/prod/dev
└── local-target/          # Cible SQLi déterministe pour les tests e2e (inchangé)
```

`envs/prod/kustomization.yaml` ne duplique pas `envs/mvp` : il le référence comme
base (`resources: [../mvp]`) et applique deux patchs JSON6902 (cert-manager,
PostgreSQL). Tous les noms d'Application ArgoCD, de release Helm et de PVC
restent identiques entre `mvp` et `prod` — c'est ce qui rend la bascule
non destructive (détails dans `kubernetes/envs/prod/README.md`).

`envs/dev` ne réutilise pas `envs/mvp` : la complexité mTLS/Temporal/Cloudflare
de prod n'a pas de sens sur un poste de développeur, donc dev est une
configuration volontairement plus simple, écrite indépendamment.

## 2. Rôle de Git, ArgoCD et leCube5080

- **Git** est la seule source de vérité. Tout changement d'infrastructure
  passe par une branche, une revue, puis un merge sur `main`.
- **ArgoCD**, installé sur leCube5080, observe en continu la branche `main`
  du dépôt et synchronise le cluster de production sur l'état déclaré dans
  `kubernetes/envs/prod`.
- **leCube5080** n'exécute jamais `git commit` ni `git push`. Il ne fait que
  recevoir les changements via ArgoCD.

## 3. Workflow développeur

```bash
git checkout -b feat/ma-fonctionnalite

make dev-create                 # crée le cluster kind "aegis-dev"
make dev-build                  # build les images locales, tag "dev-local"
make dev-deploy                 # kubectl apply -k kubernetes/envs/dev/dev-core

make dev-status                 # vérifie l'état des pods/ingress
make dev-logs SERVICE=brain-dev # suit les logs d'un service

# ... itérations de développement ...

make validate                   # yamllint + kubectl kustomize sur tous les envs
make render-dev                 # rendu local du manifeste dev (lecture seule)

make dev-destroy                # détruit le cluster kind quand terminé
```

Pour la stack complète (Temporal, MinIO, Neo4j, ClickHouse, workers) :
`make dev-build PROFILE=dev-full && make dev-deploy PROFILE=dev-full`.

Une fois les tests locaux validés : ouvrir une Pull Request vers `main` selon
le workflow Git du dépôt (voir `.github/workflows/linting.yml` pour le format
des commits `[TYPE] Message`).

## 4. Workflow de production

- **Aucun développement sur leCube5080.** Aucun push depuis leCube5080.
- ArgoCD observe `main` et synchronise automatiquement `kubernetes/envs/prod`
  (`prune: true`, `selfHeal: true`).
- **Bootstrap initial** (déjà fait aujourd'hui avec `root-app-mvp.yaml`) :
  `kubectl apply -f kubernetes/bootstrap/root-app-mvp.yaml` sur le cluster
  ArgoCD de leCube5080.
- **Bascule vers `envs/prod`** : voir la procédure détaillée et les garde-fous
  dans `kubernetes/envs/prod/README.md`. En résumé — un seul root Application
  à la fois, jamais `root-app-mvp.yaml` et `root-app-prod.yaml` appliqués
  simultanément.
- **Rollback** : `git revert` du commit fautif sur `main`. ArgoCD resynchronise
  automatiquement l'état précédent (`selfHeal: true`). Aucune commande
  `kubectl` manuelle n'est nécessaire sur leCube5080 pour un rollback standard.
- Tout script sous `scripts/prod-*.sh` se limite à la validation, au rendu et
  au bootstrap GitOps explicite — jamais à un déploiement direct des charges
  applicatives. Voir `scripts/lib/kube-context-guard.sh` : ces scripts refusent
  de s'exécuter si `PROD_KUBE_CONTEXT` n'est pas défini explicitement et ne
  correspond pas exactement au contexte `kubectl` courant.

## 5. Gestion des secrets

- Aucun secret réel n'est commité. `.env.example` (racine) et
  `kubernetes/envs/dev/secret.example.yaml` documentent la forme attendue
  avec des valeurs placeholder.
- En prod comme en dev, les services lisent le Secret Kubernetes `aegis-env`
  (mêmes clés). `make dev-deploy` construit ce Secret à partir du `.env` local
  du développeur (jamais commité) et l'applique dans le namespace `aegis-dev`.
- En prod, `aegis-env` est injecté manuellement par un opérateur sur
  leCube5080 (hors du dépôt Git).

## 6. Prérequis locaux

- `kind` (cluster `aegis-dev`, image de nœud épinglée dans
  `kubernetes/envs/dev/kind-aegis-dev.yaml`)
- `kubectl` ≥ 1.28, `docker`

Pas d'étape d'installation ArgoCD séparée : `make dev-deploy` installe ArgoCD
dans le cluster kind dès le premier lancement (les manifestes dev-core/dev-full
sont des objets `Application` ArgoCD, comme en prod, donc la CRD `Application`
et son contrôleur doivent exister avant de pouvoir les appliquer).
`make dev-deploy-argocd` est la variante "fidélité GitOps" — elle applique en
plus `root-app-dev.yaml` pour qu'ArgoCD synchronise depuis le dépôt Git distant
plutôt que depuis ton working tree local ; elle nécessite que ta branche soit
déjà poussée.

## 7. Différences dev-core / dev-full / prod

| | dev-core | dev-full | prod |
|---|---|---|---|
| Namespace | `aegis-dev` | `aegis-dev` | `aegis-system` |
| Réplicas | 1 | 1 | selon service |
| mTLS / cert-manager | désactivé | désactivé | actif (`v1.21.3`) |
| Temporal/MinIO/Neo4j/ClickHouse | absents | présents (tags/réplicas réduits) | présents |
| Cloudflare Tunnel | absent | absent | présent |
| gVisor | absent (RuntimeClass non dispo sur kind) | absent | présent si requis |
| GPU | jamais requis (Ollama tourne sur l'hôte, CPU ou GPU) | idem | idem |
| Images | build local, tag `dev-local`, `pullPolicy: Never` | idem | tags immuables explicites |
| PVC | petits (≤1Gi) | petits (≤1Gi) | tailles de production existantes |

## 8. Migration progressive depuis `envs/mvp`

1. **Aujourd'hui** : `envs/mvp` est l'état live sur leCube5080, piloté par
   `root-app-mvp.yaml`. Rien ne change pour l'instant.
2. **Cette PR** ajoute `envs/prod` (overlay de `envs/mvp`) et `envs/dev`, sans
   toucher `envs/mvp` ni `root-app-mvp.yaml`.
3. **Validation** : `make validate` doit passer ; le diff entre
   `kubectl kustomize kubernetes/envs/mvp` et
   `kubectl kustomize kubernetes/envs/prod` doit se limiter aux deux
   correctifs (cert-manager, PostgreSQL).
4. **Bascule** (opérateur, sur leCube5080, après merge) : suivre
   `kubernetes/envs/prod/README.md`. C'est une édition in-place du même
   Application ArgoCD (`aegis-prototype-mvp`), jamais deux root apps actifs
   en même temps.
5. **Retrait de `envs/mvp`** : seulement une fois `envs/prod` confirmé stable
   sur au moins un cycle de déploiement complet. À ce moment, `root-app-mvp.yaml`
   peut être supprimé et `envs/mvp` retiré dans une PR dédiée.

## Voir aussi

- [Kubernetes — manifestes et App of Apps](kubernetes.md)
- [`kubernetes/envs/prod/README.md`](../../kubernetes/envs/prod/README.md) — procédure de bascule détaillée
- [Architecture globale](architecture.md)
