# k3s-homelab

Manifests for a single-node K3s homelab cluster. Deployed with Helm (official charts) or `kubectl apply -k` (raw Kustomize manifests) via `make` — no ArgoCD, no MetalLB, no Longhorn. Uses K3s' built-in Traefik/ServiceLB and `local-path` StorageClass.

## Apps

| App | Namespace | Packaging | Hostname |
|---|---|---|---|
| Vaultwarden | `vaultwarden` | Kustomize | vault.foerst.haus |
| Sonarr / Radarr / Prowlarr / SABnzbd | `arr` | Kustomize | sonarr/radarr/prowlarr/sabnzbd.foerst.haus |
| Audiobookshelf | `audiobookshelf` | Kustomize | books.foerst.haus |
| Jellyfin | `jellyfin` | Kustomize | media.foerst.haus |
| Homarr | `homarr` | Helm | dash.foerst.haus |
| Immich | `immich` | Helm + Kustomize (Postgres) | photos.foerst.haus |
| Nextcloud | `nextcloud` | Helm + Kustomize (Postgres, Redis) | cloud.foerst.haus |

Immich and Nextcloud run their own Postgres (and Nextcloud its own Redis) as plain `Deployment`s in the app folder instead of the charts' bundled Bitnami subcharts, wired in via `externalDatabase`/`externalRedis`.

## Platform

- **cert-manager** + a `ClusterIssuer` (`letsencrypt-dns`, Cloudflare DNS-01) for TLS on every Ingress
- **Velero** (`velero` namespace): daily backup at 03:00, 30-day retention, all namespaces except `kube-system`/`velero`. Object storage is a Garage (S3-compatible) instance reachable over Netbird. No CSI snapshotter for `local-path`/NFS, so PV data is backed up via Velero's node-agent (Kopia).
- **Monitoring**: `kube-state-metrics` and `node-exporter` (Helm, namespace `monitoring`) plus a `NodePort` for Traefik's built-in metrics — no in-cluster Prometheus, scraped by one elsewhere on the LAN.

## Storage

- `local-path` — K3s' built-in dynamic provisioner, for app config/DB/cache volumes
- Static NFS PV/PVC (`storageClassName: ""`), TrueNAS at `10.10.20.220` — for media/library volumes (`arr`, `jellyfin`, `immich`, `nextcloud`)

## Deploy

```bash
make cert-manager clusterissuer   # TLS
make velero                       # backups
make monitoring                   # metrics
make arr audiobookshelf jellyfin vaultwarden homarr immich nextcloud
# or: make all
```

`make help` lists all targets. Secrets aren't applied automatically — apply the ones below before (or right after) the app that needs them, otherwise its pods will `CrashLoopBackOff`/fail auth.

## Secrets

`secrets/` is gitignored — nothing under it is committed. Create these manually and `kubectl apply -f` them into the given namespace:

| Secret | Namespace | Keys |
|---|---|---|
| `cloudflare-api-token` | `cert-manager` | `api-token` |
| `velero-secret` | `velero` | `cloud` (AWS-style credentials file for the Garage S3 endpoint) |
| `homarr-secret` | `homarr` | `SECRET_ENCRYPTION_KEY` |
| `immich-secret` | `immich` | `db-password` |
| `nextcloud-secret` | `nextcloud` | `admin-user`, `admin-password`, `postgresql-username`, `postgresql-password`, `redis-password` |
| `vaultwarden-secret` | `vaultwarden` | `ADMIN_TOKEN` |

`arr`, `audiobookshelf`, and `jellyfin` need no secrets.

## Layout

```
<app>/          namespace, PVCs, Deployment/Service/Ingress (Kustomize apps)
                or values.yaml + supporting manifests (Helm apps)
cert-manager/   ClusterIssuer
monitoring/     kube-state-metrics/node-exporter values.yaml, Traefik metrics NodePort
velero/         Helm values
secrets/        gitignored, created manually
Makefile        one target per app/step
```
