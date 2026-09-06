# k3s-homelab

Migrated subset of the apps from [`k8s-cluster`](https://github.com/t-foerst/k8s-cluster) onto a plain **K3s** cluster, deployed with **Helm** (where an official chart exists) and **kubectl/Kustomize** (where it doesn't) — no ArgoCD, no MetalLB, no Longhorn.

## What changed vs. `k8s-cluster`

| Area | `k8s-cluster` | `k3s-homelab` |
|---|---|---|
| GitOps | ArgoCD (App-of-Apps, auto-sync) | None — deploy manually via `make` / `helm` / `kubectl` |
| Ingress | Two Traefik instances (`traefik-internal` / `traefik-external`) behind MetalLB | K3s' built-in Traefik, single `traefik` IngressClass, single ServiceLB IP for everything |
| Small/DB storage | `longhorn-ssd` (replicated) | `local-path` (K3s built-in, single-node, dynamic) |
| Large media/library storage | Static NFS `PersistentVolume`s (TrueNAS) | **Unchanged** — same server, same paths, same PV/PVC pattern |
| TLS | cert-manager + Let's Encrypt (Cloudflare DNS-01) | Unchanged, but cert-manager now has to be installed explicitly (it isn't a K3s built-in) |
| App packaging | Mostly raw Kustomize manifests, Homarr already Helm | Homarr, Immich, Nextcloud → official Helm charts. Everything else has no official/maintained chart from its own project, so it stays raw manifests (per explicit choice) |

**Ingress topology note:** dropping the internal/external Traefik split means there is no more K8s-level separation between "public" apps (Jellyfin, Nextcloud, Immich, Audiobookshelf) and "internal-only" apps (Vaultwarden, Paperless, DokuWiki, Homarr, the *arr stack). All of them sit behind the one built-in Traefik/ServiceLB IP now. If you still want some apps unreachable from the internet, do it outside Kubernetes — e.g. only port-forward 443 for that one IP on your router for the hostnames that should be public, and rely on VPN/LAN-only access for the rest.

## Storage classes

- **`local-path`** — K3s' built-in dynamic provisioner. Used for every small, single-node volume: app config, databases, caches. All of these were `ReadWriteOnce` already, so the switch from `longhorn-ssd` is a drop-in replacement (no replication anymore, but this is a single-node homelab).
- **NFS (static PV/PVC, `storageClassName: ""`)** — unchanged. Same TrueNAS box (`10.10.20.220`), same export paths, same `ReadWriteMany` PVs for `*-media`/`*-library`/`*-downloads`/`*-audiobooks`/`*-metadata` volumes. These are pre-existing exports — nothing in this repo creates or manages the NFS server side.

## Helm vs. raw manifests

| App | Packaging | Why |
|---|---|---|
| Homarr | Helm (`oci://ghcr.io/homarr-labs/charts/homarr`) | Official chart |
| Immich | Helm (`immich/immich`, `https://immich-app.github.io/immich-charts`) | Official chart |
| Nextcloud | Helm (`nextcloud/nextcloud`, `https://nextcloud.github.io/helm/`) | Official chart |
| Sonarr / Radarr / Prowlarr / SABnzbd (`arr/`), Audiobookshelf, DokuWiki, Jellyfin, Vaultwarden, Paperless-ngx | Raw Kustomize manifests | No official Helm chart from the upstream project. Per your call, these stay as plain manifests instead of adopting a third-party generic chart (bjw-s app-template / TrueCharts). |

## Backups (Velero)

Cluster-wide backups via the official Velero Helm chart (`vmware-tanzu/velero`), namespace `velero`:

- **Object storage backend**: a [Garage](https://garagehq.deuxfleurs.fr/) instance (S3-compatible) reachable only over [Netbird](https://netbird.io/) at `http://backup-server.netbird.cloud:3900`, bucket `k3s-backup`. Configured as an `aws`-provider `BackupStorageLocation` (Garage speaks the S3 API, so the standard `velero-plugin-for-aws` works). `region` must be set to Garage's configured `s3_region` (`garage` here) — unlike most S3-compatible stores, Garage validates the region on every request and rejects mismatches.
  - **Networking prerequisite**: the K3s host itself needs to join the Netbird network (e.g. the `netbird` client installed on the host) — Velero's pods reach `backup-server.netbird.cloud` through the host's routing table via k3s/Flannel's SNAT-to-node-IP behavior, no in-cluster Netbird client needed. The one thing worth verifying after joining is DNS: pods resolve names through CoreDNS, which forwards to whatever's in the node's `/etc/resolv.conf` — confirm that actually reaches Netbird's MagicDNS (`kubectl run -it --rm dnstest --image=busybox -- nslookup backup-server.netbird.cloud`), and if it doesn't, use the peer's static Netbird IP in `s3Url` instead of the hostname.
- **PV data**: no CSI snapshotter exists for `local-path` or the static NFS PVs, so Velero's File System Backup (node-agent DaemonSet, Kopia uploader) is used instead — `configuration.defaultVolumesToFsBackup: true` means every pod volume gets backed up by default, no per-pod opt-in annotations needed. Kopia repositories are encrypted client-side regardless of the storage backend.
- **Schedule**: a daily backup (`velero/values.yaml`, `schedules.daily`) at 03:00, 30-day retention, covering all namespaces except `kube-system` and `velero` itself.
- **Credentials**: `velero-secret` (namespace `velero`) — an S3 access/secret key pair for Garage, mounted as an AWS-style credentials file (see `secrets/velero-secret.yaml.example`).

For Immich and Nextcloud, the chart only manages the app itself — Postgres (Immich needs the `pgvecto.rs`/pgvector-enabled image, Nextcloud needs a specific external DB) and, for Nextcloud, Redis are still small hand-written `Deployment`s in the app folder (`immich/deployment-db.yaml`, `nextcloud/deployment-db.yaml`, `nextcloud/deployment-redis.yaml`), wired up via the charts' `externalDatabase`/`externalRedis`/env-based config. This intentionally avoids the charts' bundled `mariadb`/`postgresql`/`redis` Bitnami subcharts, which now default to the frozen `bitnamilegacy/*` images.

All three Helm values files were validated locally with `helm template` against the live chart versions before being committed — see the rendered output isn't stored here, but you can always re-check with e.g. `helm template immich immich/immich -f immich/values.yaml`.

## Repo layout

```
<app>/                    namespace, PVCs, Deployments/Services/Ingress (raw apps)
                          or values.yaml (+ supporting raw manifests) for Helm apps
cert-manager/             ClusterIssuer for Let's Encrypt via Cloudflare DNS-01
secrets/                  gitignored — copy the *.example files, fill in, kubectl apply
Makefile                  one target per app/step
```

## Prerequisites

- A running K3s cluster with the built-in Traefik ingress controller and `local-path` StorageClass enabled (both are on by default).
- `helm` and `kubectl` pointed at the cluster.
- The NFS exports from `10.10.20.220` reachable from every node.
- A Cloudflare API token with DNS-edit permission on `foerst.haus`, for cert-manager's DNS-01 solver.

## Deploy order

```bash
# 1. Platform: cert-manager + ClusterIssuer
make cert-manager
kubectl apply -f secrets/cloudflare-api-token-secret.yaml   # copied from the .example + filled in
make clusterissuer

# 2. Backups: Velero
kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f secrets/velero-secret.yaml   # copied from the .example + filled in
make velero

# 3. Per app: create the namespace/secret first, then deploy
kubectl apply -f secrets/vaultwarden-secret.yaml   # etc. — see secrets/*.yaml.example
make vaultwarden
make arr
make audiobookshelf
make dokuwiki
make jellyfin
make paperless-ngx
make homarr
make immich
make nextcloud
```

Or just `make all` once every needed secret has already been applied (the Helm/Kustomize resources will otherwise come up but the app containers will `CrashLoopBackOff`/fail auth until the referenced Secret exists — nothing will be silently misconfigured).

## Secrets

Never committed. `secrets/*.yaml.example` are templates; copy them to `secrets/<name>.yaml` (gitignored), fill in real values, and `kubectl apply -f` them into the right namespace before the app that needs them comes up:

- `homarr-secret` (namespace `homarr`) — `SECRET_ENCRYPTION_KEY`
- `immich-secret` (namespace `immich`) — `db-password`
- `nextcloud-secret` (namespace `nextcloud`) — `admin-user`, `admin-password`, `postgresql-username`, `postgresql-password`, `redis-password`
- `paperless-secret` (namespace `paperless-ngx`) — `POSTGRES_PASSWORD`, `PAPERLESS_SECRET_KEY`
- `vaultwarden-secret` (namespace `vaultwarden`) — `ADMIN_TOKEN`
- `cloudflare-api-token` (namespace `cert-manager`) — `api-token`
- `velero-secret` (namespace `velero`) — `cloud` (AWS-style credentials file for the RustFS S3 endpoint)

The *arr stack, Audiobookshelf, DokuWiki, and Jellyfin need no secrets.

## Hostnames

All unchanged from `k8s-cluster` (`*.foerst.haus`), now all resolving to the single K3s Traefik ServiceLB IP instead of two separate MetalLB IPs.
