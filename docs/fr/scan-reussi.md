# Définition d'un « scan réussi » — scénario de référence E2E

Ce document fige le scénario SQLi de référence de la boucle E2E locale
(`make e2e-local-loop`) et définit précisément ce qui fait qu'un scan est
considéré comme **réussi**. Il sert de contrat pour la démo MVP et pour toute
régression de la boucle d'orchestration (`Aegis-AI-Brain`,
`GraphDrivenPentestWorkflow`).

## 1. Scénario de référence (figé)

| Élément | Valeur figée |
| --- | --- |
| Cible | HTTP server Python injecté dans un workload sandbox |
| Image | `python:3.12-alpine` |
| Workload / endpoint préféré | `aegis-target` |
| Port | `8080` |
| Endpoint vulnérable | `GET /search?q=<injection>` |
| Vulnérabilité | SQL injection (chaîne SQL concaténée sans échappement) |
| Payload canonique | `/search?q=' OR '1'='1` |
| Donnée secrète (flag) | `aegis-flag-1234`, colonne `seed_flag` de la ligne `admin@aegis.local` |
| Référence de scan | artefact topologie uploadé dans MinIO (`minio://…`) |

La cible est définie **en dur** dans
[`scripts/e2e-local-loop.sh`](../../scripts/e2e-local-loop.sh)
(fonction `write_topology_artifact`). Ne pas modifier le payload, l'endpoint ou
le flag sans mettre à jour ce document : ce sont les invariants du scénario 5/5.

## 2. Les phases du pipeline

`GraphDrivenPentestWorkflow` publie le statut du scan à chaque phase. L'ordre
nominal est :

```
PENDING → PROVISIONING → RECONNAISSANCE → SEEDING → ATTACKING
        → ANALYZING → GENERATING_REPORT → CLEANING_UP → COMPLETED
```

Un échec à n'importe quelle phase déclenche le teardown (`_cleanup`) puis le
statut terminal `FAILED`.

## 3. Politique CrewAI (décision figée)

CrewAI (l'étape « IA ») est pilotée par la variable d'environnement
`CREWAI_REQUIRED` lue par `Aegis-AI-Brain` (voir `src/config/config.py`) :

- **`CREWAI_REQUIRED=false` (défaut, prod/dev)** : comportement *best-effort*.
  Si la task queue CrewAI n'a pas de poller, ou si le crew échoue / renvoie un
  statut non-`COMPLETED`, le scan **continue** avec un rapport crew marqué
  `FAILED` et n'échoue pas. Cela évite de casser un scan quand Ollama est froid
  ou absent.
- **`CREWAI_REQUIRED=true` (scénario de référence E2E)** : comportement *strict*.
  Un crew absent, en échec ou non-`COMPLETED` fait **échouer le scan**
  (`ApplicationError` non-retryable, type `CrewAIRequiredError`). C'est ce qui
  garantit qu'un scan « réussi » 5/5 prouve que l'IA a réellement produit un
  résultat, et pas seulement le worker déterministe.

> **Pour la démo / la boucle E2E, déployer Brain avec `CREWAI_REQUIRED=true`.**

Le délai `schedule_to_start` de l'activité CrewAI est configurable via
`CREWAI_SCHEDULE_TO_START_TIMEOUT_SECONDS` (défaut **120 s**, contre 30 s
auparavant) afin de couvrir un chargement de modèle Ollama à froid sans
produire de faux négatif.

## 4. Définition exacte d'un « scan réussi »

Un scan du scénario de référence est **réussi** si et seulement si **toutes**
les conditions ci-dessous sont vraies. Chaque condition est une *preuve* vérifiée
par `make e2e-local-loop` (voir §5), pas seulement le statut final.

| # | Étape | Preuve exigée |
| --- | --- | --- |
| 1 | Progression du pipeline | Au moins une phase intermédiaire (`PROVISIONING`…`CLEANING_UP`) a été observée, puis statut terminal `COMPLETED`. |
| 2 | Exploitation + analyse | L'endpoint `GET /api/scans/{id}/vulnerabilities` renvoie **≥ 1** vulnérabilité enregistrée. |
| 3 | Résultat IA (CrewAI) | `crew_report_json` du scan a un `status` = `COMPLETED` (exigé seulement si `REQUIRE_CREW=true`). |
| 4 | Rapport | `GET /api/scans/{id}/report` renvoie HTTP 200 avec un corps non vide. |
| 5 | Preuve du flag | Le flag `aegis-flag-1234` est présent dans les vulnérabilités, leurs évidences, ou le rapport du scan. |

Si une seule de ces preuves manque, le scan **n'est pas** réussi, même si son
statut final est `COMPLETED`.

## 5. Vérification automatisée

```bash
make e2e-local-loop
```

Le script [`scripts/e2e-local-loop.sh`](../../scripts/e2e-local-loop.sh) :

1. se connecte à l'API, uploade l'artefact topologie de référence, crée un scan ;
2. poll le statut et **mémorise chaque phase traversée** ;
3. une fois `COMPLETED`, valide **chaque étape** du §4 dans l'ordre
   (`assert_pipeline_progressed`, `assert_vulnerabilities_present`,
   `assert_crew_proof`, `assert_report_generated`, `assert_flag`) ;
4. échoue (exit ≠ 0) à la première preuve manquante.

### Variables d'environnement utiles

| Variable | Défaut | Rôle |
| --- | --- | --- |
| `REQUIRE_CREW` | `true` | Exiger la preuve CrewAI (§4 #3). Mettre à `false` pour un test sans IA. |
| `EXPECTED_FLAG` | `aegis-flag-1234` | Flag attendu. |
| `TIMEOUT_SECONDS` | `900` | Budget total d'attente du scan. |
| `POLL_INTERVAL_SECONDS` | `10` | Intervalle de polling. |
| `API_BASE_URL`, `SCAN_TARGET_REF`, `ARTIFACT_BUCKET` | — | Override cluster/cible. |

> Note : la détection des phases intermédiaires (§4 #1) dépend de l'intervalle de
> polling ; les preuves #2 à #5 sont des états finaux déterministes et
> constituent les garanties fortes.

## 6. Références

- `Aegis-AI-Brain/src/workflows/graph_pentest_workflow.py` — orchestration et politique CrewAI.
- `Aegis-AI-Brain/src/config/config.py` — `CREWAI_REQUIRED`, `CREWAI_SCHEDULE_TO_START_TIMEOUT_SECONDS`.
- `Aegis-AI-Proto/docs/fr/proof-contract.md` — contrat de preuve des findings.
- `scripts/e2e-local-loop.sh` — scénario de référence et assertions.
