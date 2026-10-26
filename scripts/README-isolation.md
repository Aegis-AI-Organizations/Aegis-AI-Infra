# Aegis AI — War Room isolation test scripts

Scripts de validation de l'isolation sandbox (War Room). Aucun script ne touche un cluster client — toutes les ressources créées portent le préfixe `aegis-war-room-test-*` et sont supprimées par le `trap EXIT`.

## Prérequis

- `kubectl` configuré sur le cluster de test
- Image `busybox:1.36.0` accessible (pull depuis le registry du cluster)
- Variable `AEGIS_ALLOWED_CONTEXT` recommandée (voir [Protection de contexte](#protection-de-contexte))

## Scripts

| Script | Ce qu'il teste |
|---|---|
| `test-isolation-egress.sh` | Internet, API server, kube-system non-DNS bloqués ; DNS:53 autorisé |
| `test-isolation-gvisor.sh` | RuntimeClass gvisor présente + pod qui tourne réellement sous runsc |
| `test-isolation-quotas.sh` | Deployer-created sandbox a un ResourceQuota/LimitRange (SKIP si aucune sandbox réelle) ; [PROOF] enforcement kubectl |
| `test-isolation-multitenant.sh` | NS_A ↛ NS_B, NS_B ↛ NS_A (ClusterIP et DNS cross-namespace) |
| `test-teardown.sh` | Teardown normal, idempotence, escape hatch finalizer, dry-run emergency |

## Protection de contexte

Tous les scripts acceptent `AEGIS_ALLOWED_CONTEXT`. Si la variable est définie et que le contexte actif ne correspond pas, le script exit 2 sans créer aucune ressource :

```bash
export AEGIS_ALLOWED_CONTEXT=k3d-aegis-mvp
scripts/test-isolation-egress.sh
```

Sans la variable : WARNING affiché, exécution continue.

## Mode emergency (test-teardown.sh)

```bash
# Avec confirmation interactive (TTY requis)
scripts/test-teardown.sh --emergency

# Sans TTY (CI)
scripts/test-teardown.sh --emergency --force
```

---

## Procédure de test de mutation

Les tests de mutation vérifient que les scripts **détectent correctement une défaillance d'isolation** — c'est-à-dire qu'ils produisent un FAIL (ou SKIP explicite) plutôt qu'un faux PASS lorsque la protection est absente ou cassée.

Chaque mutation doit être appliquée et annulée isolément, sur un cluster de test dédié.

---

### Mutation 1 — NetworkPolicy supprimée

**Objectif** : vérifier que `test-isolation-egress.sh` et `test-isolation-multitenant.sh` détectent l'absence de politique réseau.

**Procédure** :

```bash
# 1. Lancer le script egress — noter les résultats de référence (tous PASS)
scripts/test-isolation-egress.sh

# 2. Supprimer la NetworkPolicy après la phase Setup (avant les tests)
#    → Le script crée la policy lui-même dans un namespace éphémère.
#    → Pour simuler l'absence : surcharger le script avec une version sans apply,
#      ou désactiver le CNI NetworkPolicy enforcement sur le node de test.
#    Alternative rapide : commenter l'apply dans le script et relancer.

# 3. Résultat attendu :
#    [FAIL] Internet IP direct (1.1.1.1:80)        — connexion réussit
#    [FAIL] Internet hostname (example.com:80)      — connexion réussit
#    [FAIL] Kubernetes API server (...)             — connexion réussit
#    [FAIL] kube-system non-DNS port (:10250)       — connexion réussit
#    Result: FAIL

# 4. Pour test-isolation-multitenant.sh sans NetworkPolicy :
#    [FAIL] NS_A → NS_B ClusterIP                  — connexion réussit
#    [FAIL] NS_B → NS_A ClusterIP                  — connexion réussit
#    Result: FAIL
```

**Résultat attendu si contrôle positif OK** : tous les tests de blocage → `[FAIL]`
**Résultat interdit** : `[PASS]` sur un test de blocage sans NetworkPolicy

---

### Mutation 2 — handler gVisor inactif

**Objectif** : vérifier que `test-isolation-gvisor.sh` détecte que gVisor ne sandboxe pas réellement.

**Procédure** :

```bash
# Scénario A : RuntimeClass absente du cluster
kubectl delete runtimeclass gvisor
scripts/test-isolation-gvisor.sh

# Résultat attendu :
#   [FAIL] Test 1 — RuntimeClass 'gvisor' not found
#   [FAIL] Test 3 — Pod timed out / phase=Failed (scheduler rejette runtimeClassName inconnu)
#   Result: FAIL

# Scénario B : RuntimeClass présente mais handler mal configuré
#   (handler pointe vers un runtime qui n'existe pas sur les nodes)
kubectl patch runtimeclass gvisor --type=merge -p '{"handler":"runsc-broken"}'
scripts/test-isolation-gvisor.sh

# Résultat attendu :
#   [PASS] Test 1 — RuntimeClass existe (handler: runsc-broken)
#   [FAIL] Test 3 — Pod Failed ou timed out (handler inconnu → pod non schedulable)
#   Result: FAIL

# Scénario C : Pod accepté par le scheduler mais tourne sur kernel hôte
#   (ex: node ignore runtimeClassName, exécute en runc)
#   → Test 5 détecte la correspondance des versions kernel :
#   [FAIL] Pod kernel (6.1.0) matches host kernel — gVisor sandbox not active
#   Result: FAIL

# Restauration
kubectl apply -f kubernetes/envs/mvp/infrastructure/gvisor-runtimeclass/manifests/runtimeclass.yaml
```

**Résultat attendu** : FAIL sur test 3 ou test 5 selon le scénario

**Résultat interdit** : PASS sur test 5 lorsque pod_kernel == host_kernel

---

### Mutation 3 — RBAC restreint

**Objectif** : vérifier que `test-isolation-quotas.sh` ne produit pas de faux PASS lorsque la création de pod est interdite par RBAC.

**Procédure** :

```bash
# Créer un ServiceAccount sans droit de création de pods dans le namespace de test,
# puis lancer le script avec ce SA (ou restreindre le kubeconfig utilisé).

# Résultat attendu pour test 4 :
#   [FAIL] Pod creation forbidden by RBAC, not LimitRange — check RBAC permissions

# Résultat interdit :
#   [PASS] LimitRange rejected pod    ← ce serait un faux PASS (RBAC != LimitRange)

# Note : les tests 1-2 [GAP] ne créent pas de pod — non affectés.
# Test 3 [PROOF] peut produire FAIL si RBAC bloque le pod within-quota.
```

**Résultat attendu** : FAIL explicite avec mention "RBAC"

**Résultat interdit** : PASS sur test 4 quand c'est RBAC qui bloque

---

### Mutation 4 — image probe invalide

**Objectif** : vérifier que les scripts ne produisent pas de faux PASS lorsque les pods probes ne démarrent pas (image inexistante → scheduling failure).

**Procédure** :

```bash
# Lancer avec une image qui n'existe pas
PROBE_IMAGE=doesnotexist:latest scripts/test-isolation-egress.sh
PROBE_IMAGE=doesnotexist:latest scripts/test-isolation-multitenant.sh

# Résultat attendu pour test-isolation-egress.sh :
#   [FAIL] Positive control: DNS failed — probe pod may not start
#   [SKIP] Internet IP direct (1.1.1.1:80) — positive control (DNS) failed: blocking result inconclusive
#   [SKIP] Internet hostname (example.com:80) — ...
#   [SKIP] ...
#   Result: FAIL  (positive control FAIL → exit 1)

# Résultat attendu pour test-isolation-multitenant.sh :
#   [FAIL] Positive control: DNS failed from NS_A
#   [SKIP] NS_A → NS_B ClusterIP — positive control failed: blocking result inconclusive
#   [SKIP] NS_A → NS_B DNS — ...
#   Result: FAIL  (positive control FAIL → exit 1)

# Résultat interdit :
#   [PASS] sur un test de blocage quand les pods probes ne démarrent pas
```

**Résultat attendu** : FAIL sur le contrôle positif + SKIP sur tous les tests de blocage

**Résultat interdit** : PASS sur des tests de blocage dont le pod probe n'a pas démarré

---

## Notes sur l'interprétation des résultats

| Résultat | Signification |
|---|---|
| `[PASS]` | Test concluant et positif |
| `[FAIL]` | Défaillance détectée ou contrôle positif échoué |
| `[SKIP]` | Test non exécuté — condition préalable absente ou contrôle positif en échec |
| `[ENV-FAIL]` | Échec dû à l'environnement du cluster de test (ex: handler gVisor non installé sur le node), pas à un bug de code ou de config |

Un SKIP sur un test de blocage après échec du contrôle positif **n'est pas un PASS**. Il faut corriger la cause (image inaccessible, node indisponible, DNS cassé) et relancer.

## Résultats — dernière exécution (orbstack, 2026-10-26)

| Script | Résultat | Détail |
|---|---|---|
| `test-isolation-quotas.sh` | PASS (2/2, 2 SKIP) | Enforcement ResourceQuota/LimitRange prouvé ; tests 1-2 SKIP (aucune sandbox réelle sur ce cluster) |
| `test-isolation-gvisor.sh` | ENV-FAIL (3/4, 1 SKIP) | RuntimeClass + config deployer OK ; `runsc` non installé sur le node orbstack — limite d'environnement local, pas un bug |
| `test-isolation-egress.sh` | **FAIL (4/6)** | Internet (IP directe et hostname) **non bloqué** malgré `default-deny-egress` ; API server et kube-system:10250 bloqués |
| `test-isolation-multitenant.sh` | **FAIL (2/6)** | NS_A ↔ NS_B **non isolés** (ClusterIP et DNS) malgré policies par namespace |
| `test-teardown.sh` | PASS (5/5) | Teardown normal, idempotence, finalizer bloqué + emergency escape hatch, dry-run, résidus — tous validés |

**⚠️ Point ouvert** : l'enforcement Cilium des `NetworkPolicy` default-deny-egress ne bloque pas le trafic pod-à-pod ni Internet sur le cluster `orbstack` au moment de ce run, alors que la PR `test/war-room-isolation` avait été mergée comme validée. À investiguer avant de considérer P1.1 comme clos (cause possible : config Cilium sur ce cluster local, ou régression depuis le merge).
