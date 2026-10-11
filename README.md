# k3s-homelab

Manifests for a single-node K3s homelab cluster. Deployed with Helm (official charts) or `kubectl apply -k` (raw Kustomize manifests) via `make` — no ArgoCD, no MetalLB, no Longhorn. Uses K3s' built-in Traefik/ServiceLB and `local-path` StorageClass.

## Apps

| App | Namespace | Packaging | Hostname |
|---|---|---|---|
| Vaultwarden | `vaultwarden` | Kustomize | vault.foerst.haus |
| Sonarr / Radarr / Prowlarr / SABnzbd / Bindery | `arr` | Kustomize | sonarr/radarr/prowlarr/sabnzbd/bindery.foerst.haus |
| Audiobookshelf | `audiobookshelf` | Kustomize | books.foerst.haus |
| Jellyfin | `jellyfin` | Kustomize | media.foerst.haus |
| Homarr | `homarr` | Helm | dash.foerst.haus |
| Immich | `immich` | Helm + Kustomize (Postgres) | photos.foerst.haus |
| Nextcloud | `nextcloud` | Helm + Kustomize (Postgres, Redis) | cloud.foerst.haus |

Immich and Nextcloud run their own Postgres (and Nextcloud its own Redis) as plain `Deployment`s in the app folder instead of the charts' bundled Bitnami subcharts, wired in via `externalDatabase`/`externalRedis`.

## Platform

- **Traefik**: K3s' bundled one, tweaked via a `HelmChartConfig` (`traefik/helmchartconfig.yaml`): HTTP permanently redirects to HTTPS, HSTS (1 year, no `includeSubDomains`) on every host via an entrypoint middleware (`traefik/middleware-hsts.yaml`), `externalTrafficPolicy: Local` so apps see the real client IP instead of ServiceLB's SNAT address (needed for Nextcloud's brute-force protection and useful logs), a 600s `readTimeout` for large uploads (Traefik v3's default is 60s), and requests/limits
- **NetworkPolicies**: every app namespace has a default-deny ingress policy and only accepts traffic from its own namespace (app ↔ DB/Redis) and from Traefik (`<app>/networkpolicy.yaml`); egress is unrestricted. K3s enforces them via its embedded kube-router
- **cert-manager** + a `ClusterIssuer` (`letsencrypt-dns`, Cloudflare DNS-01) for TLS on every Ingress
- **Velero** (`velero` namespace): daily backup at 03:00, 30-day retention, all namespaces except `kube-system`/`velero`. Object storage is a Garage (S3-compatible) instance reachable over Netbird. No CSI snapshotter for `local-path`/NFS, so PV data is backed up via Velero's node-agent (Kopia). Since Kopia copies files one by one, the live DB files aren't guaranteed to be consistent, so the databases get dumped right before their volume is backed up: Nextcloud's Postgres via a Velero pre-backup hook (`pg_dump` → `nextcloud.dump` next to `pgdata/` on the same PVC), Vaultwarden via a hook running `vaultwarden backup` (→ `/data/db-backup.sqlite3`), and Immich writes its own daily dumps to `<library>/backups`. Immich's ML model cache and Valkey job queue are excluded from backups (both are rebuilt on their own). After a restore, use these dumps if the restored DB files turn out to be broken. Velero never removes the Kopia repo of a deleted namespace; `make velero-prune-repos` does, once no backup references it anymore.
- **Monitoring**: `kube-state-metrics` (NodePort 30080) and `node-exporter` (hostNetwork, :9100) (Helm, namespace `monitoring`) plus NodePorts for Traefik's (30090) and Velero's (30091) built-in metrics — no in-cluster Prometheus, scraped by one elsewhere on the LAN.

## Restore test

Restore a namespace from a Velero backup next to the live one by mapping it to a new namespace and skipping the Ingress/cert resources, so it doesn't fight the original over its hostname:

```yaml
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: restore-test-<app>
  namespace: velero
spec:
  backupName: <backup>
  includedNamespaces: [<app>]
  namespaceMapping: {<app>: <app>-restore-test}
  excludedResources: [ingresses.networking.k8s.io, certificates.cert-manager.io, certificaterequests.cert-manager.io, orders.acme.cert-manager.io, challenges.acme.cert-manager.io]
```

This only works for apps on `local-path`. Apps with static NFS PVs (Nextcloud, Immich, *arr, Jellyfin, Audiobookshelf) can't be restored in parallel, since the PV is already bound to the live app. For those, test the DB dumps by restoring them into a throwaway Postgres instead. Delete the test namespace afterwards, or the next nightly backup picks it up.

## Storage

- `local-path` — K3s' built-in dynamic provisioner, for app config/DB/cache volumes
- Static NFS PV/PVC (`storageClassName: ""`), TrueNAS at `10.10.20.220` — for media/library volumes (`arr`, `audiobookshelf`, `jellyfin`, `immich`, `nextcloud`)
- `/mnt/Media/media` is the shared media share (`movies/`, `tv/`, `audiobooks/`), mounted by `arr` and `jellyfin` at `/media` and by Audiobookshelf with `subPath: audiobooks` at `/audiobooks`. Downloads live separately in `/mnt/Media/downloads`. Bindery (audiobooks) imports into `/media/audiobooks`, so new books show up in Audiobookshelf directly.

## Deploy

```bash
make traefik                      # Traefik overrides (client IP, upload timeout)
make cert-manager clusterissuer   # TLS
make velero                       # backups
make monitoring                   # metrics
make arr audiobookshelf jellyfin vaultwarden homarr immich nextcloud
# or: make all
```

`make help` lists all targets. Helm chart versions are pinned via `--version` in the `Makefile`, and every container image uses an exact version tag (no `:latest`) — bump them by hand when upgrading. Secrets aren't applied automatically — apply the ones below before (or right after) the app that needs them, otherwise its pods will `CrashLoopBackOff`/fail auth.

## Secrets

`secrets/` is gitignored — nothing under it is committed. Create these manually and `kubectl apply -f` them into the given namespace:

| Secret | Namespace | Keys |
|---|---|---|
| `cloudflare-api-token` | `cert-manager` | `api-token` |
| `velero-secret` | `velero` | `cloud` (AWS-style credentials file for the Garage S3 endpoint) |
| `velero-repo-credentials` | `velero` | `repository-password` (Kopia repo encryption password, set by hand instead of Velero's default; create it **before** the first backup) |
| `homarr-secret` | `homarr` | `SECRET_ENCRYPTION_KEY` |
| `immich-secret` | `immich` | `db-password` |
| `nextcloud-secret` | `nextcloud` | `admin-user`, `admin-password`, `postgresql-username`, `postgresql-password`, `redis-password` |
| `vaultwarden-secret` | `vaultwarden` | `ADMIN_TOKEN` |

`arr`, `audiobookshelf`, and `jellyfin` need no secrets.

The `velero` namespace itself is excluded from backups, so `velero-repo-credentials` only exists in the cluster: keep its password somewhere outside of it. Without it, the Kopia data on Garage can't be decrypted when rebuilding the cluster from scratch.

## Layout

```
<app>/          namespace, NetworkPolicies, PVCs, Deployment/Service/Ingress (Kustomize apps)
                or values.yaml + supporting manifests (Helm apps)
traefik/        HelmChartConfig + global HSTS middleware for K3s' bundled Traefik
cert-manager/   ClusterIssuer
monitoring/     kube-state-metrics/node-exporter values.yaml, Traefik metrics NodePort
velero/         Helm values
secrets/        gitignored, created manually
Makefile        one target per app/step
```
