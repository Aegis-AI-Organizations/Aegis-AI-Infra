# envs/prod

Production overlay for **leCube5080**. `kustomization.yaml` here does not
duplicate `envs/mvp` — it lists it as its only base (`resources: [../mvp]`)
and patches exactly two things on top:

1. cert-manager `targetRevision` → `v1.21.3`
2. PostgreSQL image → `docker.io/bitnamilegacy/postgresql:16.2.0-debian-12-r20`,
   `global.security.allowInsecureImages: true`, and the single AppArmor
   `Unconfined` exception this legacy image needs (seccomp `RuntimeDefault`,
   `runAsNonRoot`, and `allowPrivilegeEscalation: false` stay on, scoped to
   PostgreSQL only — this is not a blanket AppArmor exemption).

Every ArgoCD Application name, Helm release name, and PVC name under this
path is **byte-identical** to `envs/mvp`. That is deliberate, not an
oversight: it's what makes the cutover below non-destructive.

## Why this isn't just "mvp renamed to prod"

Renaming an ArgoCD `Application`'s `metadata.name` changes the Helm release
name ArgoCD generates for it, which changes every resource name the chart
produces (e.g. the PostgreSQL `StatefulSet` and the PVC bound to it). That
would orphan the live PostgreSQL volume on leCube5080. Keeping the names
identical and only changing `spec.source.path` (mvp → prod) avoids that
entirely — ArgoCD just re-renders the same objects with two corrected
fields.

## Cutover procedure (manual, on leCube5080, not run by this change)

Today, leCube5080's ArgoCD has one root Application
(`aegis-prototype-mvp`, from `kubernetes/bootstrap/root-app-mvp.yaml`)
pointing at `kubernetes/envs/mvp`. `kubernetes/bootstrap/root-app-prod.yaml`
is the **same** Application object, pointing at `kubernetes/envs/prod`
instead. To cut over, once this change has been reviewed and merged to
`main`:

1. Confirm `kubectl kustomize kubernetes/envs/prod` renders cleanly and the
   diff against `kubectl kustomize kubernetes/envs/mvp` is exactly the
   cert-manager + PostgreSQL changes above (see `make validate`).
2. On leCube5080, with ArgoCD already tracking `main`: edit the existing
   `aegis-prototype-mvp` Application's `spec.source.path` from
   `kubernetes/envs/mvp` to `kubernetes/envs/prod` — either by applying
   `kubernetes/bootstrap/root-app-prod.yaml` directly (same name, so it's an
   update, not a new object), or by letting ArgoCD pick up the committed
   change if `root-app-mvp.yaml` and `root-app-prod.yaml` are reconciled into
   one file at that point.
3. **Never apply both root-app-mvp.yaml and root-app-prod.yaml as separate,
   simultaneously-active Applications.** They own the same child
   Applications (`aegis-postgres-mvp`, `aegis-cert-manager`, ...); two root
   apps both claiming them causes ArgoCD `SharedResourceWarning`s and
   unpredictable sync behavior.
4. Watch `aegis-cert-manager` and `aegis-postgres-mvp` sync. The PostgreSQL
   StatefulSet restarts pods with the new image; the PVC is untouched
   because its name never changes.
5. Once `envs/prod` has been the live source for a full deploy cycle with no
   issues, `envs/mvp` can be retired (see the repo-root migration docs for
   the exact order).

This procedure is documented here for the operator to run manually. Nothing
in this repository change applies it automatically, and no command in
`scripts/` targets the production cluster without an explicit, matching
`PROD_KUBE_CONTEXT`.
