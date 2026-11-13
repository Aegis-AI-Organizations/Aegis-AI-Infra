# Aegis AI — Benchmark de dimensionnement infrastructure

Calculé à partir des requests/limits réelles et de la config d'autoscaling commitées dans
`kubernetes/envs/mvp/*/values.yaml`, `Aegis-AI-Worker-Deployer/internal/deployer/config.go`,
et de la configuration Ollama/hôte réellement en service sur ce MVP (vérifié le 2026-11-09).

Ce n'est pas un benchmark issu de tests de charge — c'est une estimation de capacité
dérivée des requests/limits configurées par la plateforme elle-même, des plafonds
d'autoscaling KEDA, et de l'empreinte réelle (modèles + matériel) de la couche LLM
auto-hébergée. Aucun test de charge débit/latence n'existe encore dans ce repo.

**Cette version remplace une précédente qui ne couvrait que les microservices déployés
sur k8s et omettait la couche d'inférence LLM auto-hébergée — le plus gros consommateur
de ressources de la plateforme. Cette couche est désormais traitée en section de premier
plan, pas en annexe.**

**Objectif de ce document : servir de base chiffrée pour négocier l'allocation d'un
serveur (VPS/dédié) auprès de l'école, incluant l'hébergement de la couche IA
auto-hébergée (Ollama) sur cette même machine.**

---

## A. La demande

### Constat actuel

Aegis AI tourne aujourd'hui entièrement sur **un MacBook Pro personnel** (Apple M4 Pro,
48 Go de mémoire unifiée). Cette seule machine fait simultanément :
- tourner le cluster k8s complet (Brain, Api-Gateway, Dashboard, BDD, workers, etc.) ;
- héberger les trois modèles d'IA auto-hébergés (Ollama) qui font fonctionner l'agent de
  pentest ;
- servir `app.aegis-ai.fr` en production, via un tunnel Cloudflare.

Au palier d'usage déjà configuré par la plateforme elle-même (5 scans simultanés, pas un
scénario extrême — c'est le plafond d'autoscaling actuel), l'usage mémoire combiné
atteint **35 à 39 Go en usage réaliste, jusqu'à 50-54 Go en pointe — soit plus que la
mémoire disponible sur la machine actuelle.** Voir sections B à G pour le détail chiffré
et sourcé qui justifie cette demande.

### Un ordinateur portable n'est pas une infrastructure de production viable

Indépendamment de la question de capacité ci-dessus, **héberger le site public
(`app.aegis-ai.fr`, y compris la landing page) sur un ordinateur portable personnel n'est
pas acceptable comme solution durable**, même si la machine avait des ressources
illimitées :

- Un laptop se met en veille, se ferme, se déplace, perd le Wi-Fi, redémarre pour une
  mise à jour — chacun de ces événements, normaux sur une machine personnelle, coupe
  l'accès public au site et à l'API pour tout visiteur, prospect ou évaluateur pendant
  cet incident.
- Aucune alimentation redondante, aucune connexion réseau redondante, aucun SLA : c'est
  une machine de développeur, pas un serveur — elle n'a jamais été conçue pour tourner
  24/7 sans interruption.
- Le tunnel Cloudflare masque ce risque à un visiteur externe jusqu'au moment précis où
  l'incident se produit — à ce moment-là, c'est la vitrine publique du projet (et pas
  seulement un environnement de dev) qui tombe, sans aucun avertissement ni page de
  statut.
- Cette dépendance repose entièrement sur la disponibilité personnelle d'un seul
  contributeur et de son matériel perso — un point de défaillance unique qui n'a aucun
  rapport avec la qualité du code ou de l'architecture applicative.

Même un serveur modeste mais dédié, avec une vraie alimentation et un vrai réseau,
réglerait ce problème de disponibilité indépendamment de tout dimensionnement CPU/RAM/GPU
détaillé plus bas — c'est un argument de fiabilité, pas de capacité.

### Spec recommandée à demander

| Ressource | Minimum viable | **Recommandé** | Pourquoi |
|---|---|---|---|
| CPU | 8 vCPU | **16 vCPU** | ~8 vCPU pour le cluster k8s à 5 scans simultanés (section H) + marge pour le processus Ollama et la croissance |
| RAM système | 16 Go | **32 Go** | Côté k8s seul (~16Gi au palier max) ; sur un serveur GPU dédié, les poids des modèles vivent en VRAM, pas en RAM système, donc ce chiffre reste modéré contrairement à la machine actuelle (mémoire unifiée) |
| GPU | 1× GPU 24 Go VRAM | **1× GPU ≥48 Go VRAM** (classe NVIDIA L40S / A100-40 Go) | Les 3 modèles (Planner/Guider/Executor) pèsent 18.5 Go de poids seuls ; 48 Go laisse une vraie marge de cache KV sous charge concurrente (section G) — 24 Go suffit à peine à charger les 3 modèles sans aucune marge |
| Stockage | 200 Go SSD/NVMe | **500 Go SSD/NVMe** | BDD (avec persistence activée, actuellement absente — section I), MinIO, ClickHouse, Neo4j, modèles Ollama, images de conteneurs, marge de croissance |
| Réseau | IP publique, ports 80/443 ouverts | Idem | Pour continuer à servir `app.aegis-ai.fr` |

**Si le GPU ≥48 Go n'est pas disponible dans l'offre de l'école :** une alternative
viable à plus court terme est 1× GPU 24 Go (le minimum viable ci-dessus), avec un
compromis assumé — les trois modèles tiennent en mémoire mais sans marge pour la
concurrence réelle, ce qui limitera le nombre de scans simultanés bien en-dessous du
plafond de 5 déjà configuré par la plateforme (section G détaille ce compromis).

**Ce que ça résout concrètement :**
- Sort l'IA et le cluster applicatif de la machine perso d'un contributeur, qui sert
  aussi la prod en ce moment (section A ci-dessus, et [[project_synology_local_dev_instability]]
  pour les instabilités déjà rencontrées liées à cette config).
- Donne une vraie marge pour monter en charge jusqu'au plafond de 5 scans simultanés déjà
  configuré dans la plateforme, sans se faire OOM-killer.
- Permet d'activer enfin la persistence de la base de données (section I), actuellement
  désactivée faute d'environnement stable pour la justifier.

---

## B. Résumé exécutif

Aegis AI a **deux couches de calcul distinctes à dimensionner**, actuellement hébergées
sur **une seule machine** :

1. **Le control plane k8s et les workers** (Brain, Api-Gateway, Dashboard, Landing,
   Postgres, Redis, MinIO, Neo4j, ClickHouse, Temporal, et les quatre types de workers
   scalés par KEDA) — du CPU/RAM de conteneur classique, dimensionné aux sections D–F.
2. **L'inférence LLM auto-hébergée via Ollama** — trois modèles (8B, 8B, 16B) que les
   rôles Planner/Guider/Executor de CrewAI appellent directement sur la machine hôte,
   **entièrement hors de Kubernetes** — dimensionné à la section G. Ce n'est pas une
   infrastructure optionnelle : le pipeline d'agents pentest ne peut pas tourner sans
   elle, et elle domine le budget mémoire.

| Palier | Scans simultanés | CPU k8s (req / burst) | Mémoire k8s (req / burst) | Mémoire Ollama (modèles chargés) | **Mémoire combinée (req-équivalent / burst)** |
|---|---|---|---|---|---|
| Idle | 0 | 2.35 / 5.45 vCPU | 5.6Gi / 11.25Gi | 0 (déchargée après timeout) | **5.6Gi / 11.25Gi** |
| Typique | 3 | 3.85 / 9.85 vCPU | 8.4Gi / 18.75Gi | ~20–22 Go | **~28–30Gi / ~39–41Gi** |
| Max configuré | 5 | 5.35 / 14.25 vCPU | 11.2Gi / 26.25Gi | ~24–28 Go | **~35–39Gi / ~50–54Gi** |

La machine actuelle (MacBook Pro, Apple M4 Pro, **48 Go de mémoire unifiée**) tient le
palier idle, mais **dès le palier typique (3 scans simultanés, pas un pic exceptionnel)
le besoin en pointe dépasse déjà les 48 Go de cette machine, et le palier max configuré
les dépasse largement.** C'est le vrai constat : la plateforme a besoin de plus de
mémoire que ce que la machine actuelle peut fournir, même en usage courant — pas
seulement dans un scénario extrême.

---

## C. Où les choses tournent réellement

| Composant | Tourne dans | Pourquoi ça compte pour le dimensionnement |
|---|---|---|
| Brain, Api-Gateway, Dashboard, Landing | Kubernetes (`kubernetes/envs/mvp/*`) | Les requests/limits de conteneur classiques s'appliquent |
| Postgres, Redis, MinIO, Neo4j, ClickHouse, Temporal | Kubernetes (`infrastructure/*`) | Idem |
| crewai-worker, deployer-worker, pentest-worker, ingest-worker | Kubernetes, scalés par KEDA selon la profondeur des queues Temporal | Scalent de 0/1 → N avec le volume de scans |
| Sandbox cible par scan (`aegis-war-room-<scan-id>`) | Kubernetes, namespace éphémère créé/détruit par scan | Scale 1:1 avec les scans simultanés |
| **Ollama (LLMs Planner/Guider/Executor)** | **Machine hôte, hors Kubernetes** (les variables `*_API_BASE` de `crewai-worker` pointent toutes vers `http://host.docker.internal:11434`) | **Pas conteneurisé, pas autoscalé, partage la RAM de l'hôte avec tout ce qui précède** |

Tout ce tableau tourne actuellement sur **une seule machine physique**, qui sert aussi
`app.aegis-ai.fr` publiquement via le tunnel `aegis-cloudflared` (voir
[[project_synology_local_dev_instability]]). Ça aggrave le risque de la section G : un
pic mémoire côté LLM entre en concurrence directe avec le trafic de production servi par
la même machine.

---

## D. Control plane k8s toujours actif (1 replica chacun, régime stable)

| Service | CPU req | CPU lim | Mém req | Mém lim | Source |
|---|---|---|---|---|---|
| brain | 100m | 300m | 256Mi | 512Mi | `brain/values.yaml` |
| api-gateway | 100m | 200m | 128Mi | 256Mi | `api-gateway/values.yaml` |
| dashboard | 50m | 100m | 64Mi | 128Mi | `dashboard/values.yaml` |
| landing | 50m | 100m | 64Mi | 128Mi | `landing/values.yaml` |
| postgres (partagé : BDD app + persistence/visibility Temporal, 1 instance, 3 BDD logiques) | 250m | 500m | 512Mi | 1Gi | `infrastructure/postgres/application.yaml` |
| redis | 100m | 250m | 256Mi | 512Mi | `infrastructure/redis/values.yaml` |
| minio | 250m | 500m | 512Mi | 1Gi | `infrastructure/minio/values.yaml` |
| neo4j | 500m | 1000m | **2Gi** | 3Gi | `infrastructure/neo4j/values.yaml` — **500m CPU et 2Gi mémoire sont le plancher imposé par le chart officiel `neo4j/neo4j` lui-même** (validé via `helm template`, pas une estimation : le chart rejette toute valeur en dessous) |
| clickhouse | 250m | 500m | 512Mi | 1Gi | `infrastructure/clickhouse/values.yaml` |
| temporal server | 250m | 500m | 512Mi | 1Gi | `infrastructure/temporal/temporal-values.yaml` — un seul déploiement monolithique `server` (mode auto-setup), pas 4 services séparés |

**Sous-total, les 10 services (tous désormais pinnés explicitement) :** requests **1900m
CPU / 4864Mi (4.75Gi)**, limits **3950m CPU / 8704Mi (8.5Gi)**.

**Révision du 2026-11-13 :** `neo4j`, `clickhouse`, et `temporal server` n'avaient aucune
ressource fixée lors de la première version de ce document ; une estimation combinée de
~1.5–2.5 vCPU / 3–5 Go avait été utilisée en leur absence. Ils sont désormais pinnés
explicitement (PR #82), et la validation par `helm template` a révélé que **le chart
officiel de Neo4j impose à lui seul un plancher de 500m CPU et 2Gi mémoire** — plus que
ce que l'estimation initiale attribuait aux trois services combinés. Les totaux de ce
document ont été recalculés avec ces chiffres réels, pas des estimations.

---

## E. Workers (scalés par KEDA selon la profondeur des queues Temporal)

| Worker | replicas min | replicas max | CPU req/pod | CPU lim/pod | Mém req/pod | Mém lim/pod |
|---|---|---|---|---|---|---|
| crewai-worker | 1 | **5** | 250m | 1000m | 512Mi | 2Gi |
| deployer-worker | 1 | 10 | 100m | 300m | 256Mi | 512Mi |
| pentest-worker | 1 | 20 | 100m | 200m | 128Mi | 256Mi |
| ingest-worker | 0 | 20 | 100m | 300m | 256Mi | 512Mi |

**Plancher toujours actif** (replicas min, ingest-worker peut être à 0) : requests
**450m / 896Mi**, limits **1500m / 2816Mi**.

**Le vrai plafond du nombre de scans simultanés, c'est le `maxReplicaCount: 5` de
`crewai-worker`**, pas la taille du cluster. `deployer-worker` (10) et `pentest-worker`
(20) ont plus de marge, mais chaque scan a besoin d'exactement un run d'agent CrewAI,
donc ce MVP supporte **au maximum 5 scans simultanés** tant que ce chiffre n'est pas
relevé — et la section G montre que le relever coûte bien plus cher que d'ajouter de la
capacité k8s, parce que chaque scan simultané supplémentaire ajoute de la pression
concurrente sur les trois mêmes modèles Ollama.

---

## F. Sandbox par scan (namespace cible éphémère)

Depuis `Aegis-AI-Worker-Deployer/internal/deployer/config.go` :

- **ResourceQuota du namespace** (plafond, pas usage réel) : 2 vCPU / 4Gi en requests,
  8 vCPU / 8Gi en limits, max 20 pods.
- **LimitRange par défaut par conteneur** (pas de profil explicite — la plupart des
  cibles) : 100m req / 200m lim CPU, 128Mi req / 256Mi lim mém.
- **Profil de ressources `jvm`** (opt-in, pour les cibles JVM comme le sandbox Struts2
  CVE-2017-5638 — le profil par défaut l'a fait OOM-killer) : 500m req / 1 vCPU lim CPU,
  512Mi req / **4Gi** lim mém. La limite de 4Gi est mesurée empiriquement, pas devinée :
  1536Mi l'a fait OOM-killer ~49s après le boot même à l'arrêt ; 2560Mi a survécu à
  l'idle mais s'est fait OOM-killer ~90s dans un vrai scan nuclei.
- Topologie de sandbox typique (cible + `external-api-mock`, 2 pods-équivalents, profil
  par défaut) : **~200m req / 400m lim CPU, 256Mi req / 512Mi lim mém.** Une sandbox à
  cible JVM à la place : **~500m req / 1 vCPU lim CPU, 512Mi req / 4Gi lim mém** pour ce
  seul pod.

### Coût k8s marginal par scan simultané supplémentaire (cible par défaut, non-JVM)

Somme de : +1 pod crewai-worker, +1 pod deployer-worker, +1 pod pentest-worker, +1 pod
ingest-worker, +1 sandbox profil par défaut (2 pods) :

| | CPU req | CPU lim | Mém req | Mém lim |
|---|---|---|---|---|
| **Par scan (côté k8s uniquement)** | 750m | 2.2 vCPU | 1.4Gi | 3.75Gi |

Un scan à cible JVM coûte environ **+300m req CPU, +3.25Gi lim mém** de plus, presque
entièrement sur la limite mémoire. Ceci ne couvre que le coût côté k8s — la section G
ajoute le coût côté Ollama de ce même scan supplémentaire, qui est plus important.

---

## G. Inférence LLM locale (Ollama) — le coût dominant

Les trois rôles d'agent de CrewAI sont configurés dans `crewai-worker/values.yaml` pour
appeler une **instance Ollama auto-hébergée sur la machine hôte elle-même** :

```
PLANNER_PROVIDER=ollama   PLANNER_MODEL=llama3.1:8b                                    PLANNER_API_BASE=http://host.docker.internal:11434
GUIDER_PROVIDER=ollama    GUIDER_MODEL=WhiteRabbitNeo/Llama-3.1-WhiteRabbitNeo-2-8B     GUIDER_API_BASE=http://host.docker.internal:11434
EXECUTOR_PROVIDER=ollama  EXECUTOR_MODEL=deepseek-coder-v2:16b                          EXECUTOR_API_BASE=http://host.docker.internal:11434
```

Pas un service déployé sur k8s, pas une API hébergée (OpenAI/Anthropic/etc.) — un
processus bare-metal sur l'hôte, invisible à tout chiffre `kubectl`/Helm ci-dessus.

### Empreinte mesurée

| Rôle | Modèle | Taille disque (Ollama, quantifié) |
|---|---|---|
| Planner | `llama3.1:8b` | 4.9 Go |
| Guider | `WhiteRabbitNeo/Llama-3.1-WhiteRabbitNeo-2-8B` | 4.7 Go |
| Executor | `deepseek-coder-v2:16b` | 8.9 Go |
| **Total, 3 modèles** | | **18.5 Go** |

Confirmé sur la machine de dev/hôte actuelle via `system_profiler` et `ollama list` :
**MacBook Pro, Apple M4 Pro, 14 cœurs (10P+4E), 48 Go de mémoire unifiée.**

### Implications pour le dimensionnement

- Charger les trois modèles en mémoire simultanément — nécessaire pour éviter le
  chargement/déchargement en boucle dès qu'un pipeline de scan appelle les trois rôles,
  ou que plusieurs scans sollicitent des rôles différents en même temps — coûte
  **~18.5 Go rien que pour les poids**, avant tout cache KV pour les générations en cours.
- Chaque génération en cours ajoute de la mémoire, proportionnellement à la longueur de
  contexte et à la taille de batch. Prévoir **+30–50%** au-dessus de l'empreinte de base
  des poids en charge concurrente réelle : **~24–28 Go de working set réaliste** pour 3
  modèles avec quelques requêtes simultanées.
- À **5 scans simultanés** (le plafond déjà configuré en section E), si deux ou trois
  scans sollicitent le rôle Executor en même temps, Ollama sert des requêtes concurrentes
  sur un modèle 16B en plus des deux autres — 24–28 Go est un *plancher* pour ce
  scénario, pas un plafond.
- La mémoire unifiée Apple Silicon fait que GPU et CPU partagent un seul pool — il n'y a
  pas de VRAM séparée à vérifier indépendamment, et pas de chiffre vCPU d'accélérateur
  dédié qui capture le coût d'inférence comme le font les chiffres CPU des sections D–F.
  Le goulot d'étranglement d'Ollama ici, c'est **la bande passante mémoire et la mémoire
  unifiée totale, pas le nombre de cœurs** — les calculs CPU k8s de ce document ne sont
  pas comparables au coût de calcul d'Ollama, et ne l'incluent pas.
- Cette couche **partage exactement la même machine à 48 Go** que tout le cluster k8s des
  sections D–F. En empilant le palier k8s « Max configuré » de la section E (11.2Gi
  requests / 26.25Gi limits) avec ~24–28 Go pour Ollama, l'usage combiné réaliste atteint
  **~35–39 Go en requests-équivalent, et potentiellement plus de 50 Go en pointe** — avant
  même l'overhead de base de macOS/Docker Desktop/OrbStack (typiquement 2–6 Go).

### S'il faut sortir ça de la machine de dev unique

Recommandé au-delà de l'échelle solo-dev, vu que cette même machine sert aussi
`app.aegis-ai.fr` en production via le tunnel Cloudflare :

- Une seule instance GPU avec **≥24 Go de VRAM** (ex. NVIDIA L4, A10G) peut tout juste
  contenir les poids des trois modèles, avec quasiment aucune marge pour le cache KV
  concurrent — viable seulement à faible/sans concurrence.
- Pour une vraie marge de concurrence de scans, prévoir **≥48 Go de VRAM** (ex. L40S,
  A100-40Go) ou répartir les trois rôles sur deux instances GPU ou plus, pour qu'aucun
  modèle ne soit en concurrence de charge avec les autres.
- Alternative : déporter un ou plusieurs rôles (le plus plausible étant Planner, le rôle
  le plus léger/générique) vers un fournisseur d'API hébergée plutôt que de l'auto-héberger,
  en échangeant un coût au token contre la suppression de l'empreinte de ce modèle du
  dimensionnement infra. C'est une décision produit/coût, pas purement infra — signalé
  ici car ça change chaque chiffre de ce document, pas quelque chose à trancher
  unilatéralement dans un benchmark de dimensionnement.
- Un hôte Ollama dédié (pas partagé avec le cluster k8s ni le tunnel public) a aussi
  besoin de son propre overhead CPU/RAM système modeste pour le processus de service
  lui-même — environ **2–4 vCPU, 4–8 Go de RAM système** en plus des poids des modèles,
  s'il est provisionné comme serveur d'inférence dédié plutôt que partagé avec une
  machine de dev.

---

## H. Totaux combinés par palier de concurrence

| Palier | Scans simultanés | CPU k8s (req / burst) | Mémoire k8s (req / burst) | Mémoire Ollama | **Mémoire combinée (req-équivalent / burst)** |
|---|---|---|---|---|---|
| Idle | 0 | 2.35 / 5.45 vCPU | 5.6Gi / 11.25Gi | 0 (déchargée après timeout) | **5.6Gi / 11.25Gi** |
| Typique | 3 | 3.85 / 9.85 vCPU | 8.4Gi / 18.75Gi | ~20–22 Go | **~28–30Gi / ~39–41Gi** |
| Max configuré | 5 | 5.35 / 14.25 vCPU | 11.2Gi / 26.25Gi | ~24–28 Go | **~35–39Gi / ~50–54Gi** |

Chaque colonne k8s = sous-total défini de la section D + plancher workers de la section E
+ estimation des services non définis de la section D + N × coût marginal de la
section F, N = scans simultanés au-delà du 1 déjà couvert par le `minReplicaCount: 1` de
chaque worker. Le palier idle suppose qu'Ollama décharge ses modèles après son timeout
d'inactivité ; si les scans tournent assez fréquemment pour qu'Ollama ne soit jamais
vraiment inactif, ajouter le chiffre Ollama du palier « typique » même à faible nombre de
scans — il y a aussi un **coût de démarrage à froid** ponctuel (10–30s+ pour charger un
modèle 8–16B depuis le disque) à la première invocation d'un rôle après une période
d'inactivité, qui affecte la latence du scan, pas seulement la mémoire.

**Provisionnement recommandé en restant sur du matériel à mémoire unifiée comparable
(ex. Apple Silicon) :** **≥64 Go de mémoire unifiée** pour faire tourner le palier max
configuré avec une vraie marge, contre les 48 Go actuels déjà tendus à ce palier.

**Provisionnement recommandé en séparant infra k8s et GPU :** côté k8s, **~8 vCPU /
16 Go** de capacité nœud schedulable pour 5 scans simultanés avec marge standard (basé
sur les requests, selon la recommandation d'origine de la section E) ; côté GPU,
**≥48 Go de VRAM** selon la section G, sur du matériel entièrement séparé à la fois du
cluster k8s et de ce qui sert le trafic public.

---

## I. Stockage

| Composant | Taille | Remarque |
|---|---|---|
| postgres | **0 — persistence désactivée** (`persistence.enabled: false`) | Les données ne vivent que dans le stockage éphémère du pod. Le plus gros risque de perte de données de la config MVP actuelle — un redémarrage de pod perd la BDD app **et** les stores persistence/visibility de Temporal. Nécessite un PVC avant d'être autre chose qu'un environnement jetable. |
| minio | 10Gi | `infrastructure/minio/values.yaml` |
| clickhouse | 8Gi | `infrastructure/clickhouse/values.yaml` |
| neo4j | *taille non précisée* (`mode: defaultStorageClass`, pas de `size:` explicite) | Le défaut du storage class/chart s'applique ; à fixer explicitement avant de s'y fier. |
| redis | pas de volume persistant configuré | Acceptable pour son usage (cache/signalisation pub-sub éphémère), pas pour quoi que ce soit censé survivre à un redémarrage. |
| Stockage modèles Ollama | 18.5 Go (3 modèles, voir section G) + d'autres éventuellement présents sur l'hôte (`qwen3:14b` 9.3 Go, `qwen3:8b` 5.2 Go, `nomic-embed-text` 274 Mo sont présents sur l'hôte mais ne sont référencés par aucun manifeste k8s commité — probablement du dev-only, à confirmer qu'ils ne sont pas utilisés silencieusement) | Pas géré par k8s du tout, vit sur le disque local de l'hôte. |

---

## J. Mises en garde

- Ce sont des requests/limits **configurées** plus une empreinte hôte/modèle **mesurée**,
  pas des résultats de test de charge. Aucun benchmark débit/latence réel n'existe dans
  ce repo.
- `neo4j`, `clickhouse` et `temporal server` ont désormais des ressources k8s fixées
  explicitement (PR #82, 2026-11-13) et validées par `helm template` ; les chiffres de la
  section D sont des valeurs de config réelles, plus des estimations.
- Le plafond de 5 scans simultanés est un **choix de configuration `maxReplicaCount`
  KEDA**, pas une limite matérielle côté k8s — mais la section G montre que le relever
  coûte bien plus cher en réalité que d'ajouter de la capacité k8s, parce que ça
  multiplie directement la pression concurrente sur les trois mêmes modèles Ollama qui
  partagent la mémoire d'un seul hôte.
- Les chiffres supposent une seule topologie de sandbox avec un seul workload cible par
  scan ; un scan dont la topologie déclare plusieurs workloads cibles coûte plus cher par
  scan que le chiffre de la section F.
- Les estimations mémoire Ollama (section G) sont dérivées des tailles de modèles
  quantifiés sur disque plus une hypothèse standard de marge de cache KV, pas d'un
  profilage en direct sous charge CrewAI concurrente réelle. Si ce chiffre compte pour
  une vraie décision de provisionnement, lancer `ollama ps` pendant un vrai test de
  charge multi-scans pour obtenir la mémoire résidente réelle plutôt que cette
  estimation.
