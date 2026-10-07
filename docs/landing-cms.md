# Landing CMS rollout (Landing #11 / Infra #69)

The editorial CMS owns its users, posts, folders and media metadata. It does not use the product API Gateway or product database. The MVP uses SQLite and media on one persistent volume, one replica and Recreate updates. A PostgreSQL/shared-object-storage migration is needed before multiple writers.

## Opt-in rollout

`landing/values-cms.yaml` is an **opt-in overlay**, not active in the existing Argo Application. Do not switch the running application until the prerequisites below are satisfied. This PR does not deploy a cluster or change the current landing image.

1. Merge the Landing CMS hardening PR (Landing #13) and verify its release image exists. Use its immutable release tag, never a moving latest tag.
2. Select the storage class for the target cluster (`local-path` is the local MVP default). Protect and back up the volume; Helm/Argo prune annotations do not substitute for backups.
3. Create `landing-cms-config` in `aegis-system` from a protected env file containing a persistent `PAYLOAD_SECRET` (at least 32 random characters). No secret values belong in Git.
4. Provision the first administrator privately: mount a separate Kubernetes Secret file, e.g. `/run/secrets/cms-admin-password`, and supply `CMS_BOOTSTRAP_EMAIL` and `CMS_BOOTSTRAP_PASSWORD_FILE` on the initial startup. Password must have at least 16 characters. This internal bootstrap only runs when no user exists. Remove the bootstrap variables, mount and Secret afterward. The production HTTP setup route and anonymous bootstrap API are blocked by Landing #13.
5. In a reviewed rollout change, append `../../envs/mvp/landing/values-cms.yaml` after `values.yaml` in the Application's `valueFiles`, and pin the verified image tag. Keep replicaCount 1 and strategy Recreate. The node user writes `/app/data` through fsGroup 1000.
6. Render with `helm template landing kubernetes/charts/aegis-service -f kubernetes/envs/mvp/landing/values.yaml -f kubernetes/envs/mvp/landing/values-cms.yaml --set image.tag=VERIFIED_RELEASE`. Check the rendered secret, PVC, image and network policies before syncing Argo.
7. Verify rollout, authenticated admin access, FR/EN journal, image upload, and a restart that preserves the content. Rollout verification is outstanding until a cluster is available.

## Mailpit now, SMTP later

Mailpit is an internal ClusterIP service. It captures mail and has no relay configured; it does not send real emails. Only landing pods may connect to SMTP port 1025. Access the mailbox with `kubectl -n aegis-system port-forward svc/landing-mvp-mailpit 8025:8025 --address 127.0.0.1`. There is no public ingress. Messages are ephemeral and contain reset links: do not publish the mailbox.

Locally use `mailpit --listen 127.0.0.1:8025 --smtp 127.0.0.1:1025`, or a dedicated Docker container with both ports bound to 127.0.0.1. The Landing repository configures `SMTP_HOST=127.0.0.1`, `SMTP_PORT=1025`; run `npm run test:mailpit` there.

For a real provider, replace SMTP_HOST/PORT, set the verified SMTP_FROM_ADDRESS, configure authentication via Secret and TLS using SMTP_SECURE (implicit TLS) or SMTP_REQUIRE_TLS (STARTTLS). Add only that provider's required egress rule. Disable cmsMailpit after validation. Real SMTP is intentionally deferred by the project owner.

## Backup and restoration

Stop CMS writes first: pause Argo automated reconciliation for the maintenance window and scale the landing workload to zero. Never copy media during uploads/deletions. Mount/copy the stopped volume into a protected operator workspace, then run:

```sh
python3 scripts/cms-snapshot.py /protected/current-data /protected/backup-YYYY-MM-DD
python3 scripts/cms-snapshot.py /protected/backup-YYYY-MM-DD /protected/restored-data
python3 scripts/test-cms-snapshot.py
```

The tool validates SQLite integrity, copies a consistent SQLite backup plus media, and refuses to overwrite a destination. Back up PAYLOAD_SECRET separately in the secret manager. Encrypt off-host copies and define retention. A snapshot on the same disk is not disaster recovery.

Restore into a new empty volume, check ownership for uid/gid 1000, verify content and then point the single stopped workload at that volume. Pin the matching application image, restart, and re-enable Argo only after validation. To roll back a schema change, restore the matching pre-migration snapshot and image together; never run an old image against an unverified newer schema. Do not delete the previous volume until restoration has been verified.

Automated tests validate local SQLite/media snapshot round trips and Helm rendering. Live PVC provisioning and disaster recovery on the target cluster remain operational rollout checks.
