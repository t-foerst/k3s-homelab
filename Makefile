.PHONY: help traefik cert-manager clusterissuer velero velero-prune-repos monitoring arr audiobookshelf jellyfin vaultwarden homarr immich nextcloud all

help:
	@echo "Platform:      make traefik cert-manager clusterissuer velero monitoring"
	@echo "Maintenance:   make velero-prune-repos"
	@echo "Raw manifests: make arr audiobookshelf jellyfin vaultwarden"
	@echo "Helm apps:     make homarr immich nextcloud"
	@echo "Everything:    make all"
	@echo ""
	@echo "Secrets are NOT applied automatically. Copy the matching file(s) from"
	@echo "secrets/*.yaml.example, fill in real values, and 'kubectl apply -f' them"
	@echo "before (or right after) deploying the app that needs them."

## Chart versions are pinned on purpose: bump --version by hand when upgrading.

## --- k3s' bundled Traefik (overrides via HelmChartConfig) ---

traefik:
	kubectl apply -k traefik/

## --- Platform (not built into k3s) ---

cert-manager:
	helm repo add jetstack https://charts.jetstack.io --force-update
	helm upgrade --install cert-manager jetstack/cert-manager \
		--namespace cert-manager --create-namespace \
		--version v1.21.1 --set crds.enabled=true --wait

clusterissuer:
	kubectl apply -f cert-manager/clusterissuer.yaml

## --- Backups (Velero, backed by Garage/S3 on the external backup-server, via Netbird) ---

velero:
	helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts --force-update
	helm upgrade --install velero vmware-tanzu/velero --version 12.1.0 \
		--namespace velero --create-namespace \
		-f velero/values.yaml

## Velero never removes the Kopia BackupRepository of a deleted namespace, so its
## hourly maintenance jobs keep running forever. This deletes the repos of gone
## namespaces once no backup references them anymore. Run it a few days after
## the last such backup expired, so Kopia maintenance has already freed the data.
velero-prune-repos:
	@for repo in $$(kubectl get backuprepositories -n velero -o jsonpath='{range .items[*]}{.metadata.name}={.spec.volumeNamespace}{"\n"}{end}'); do \
		name=$${repo%%=*}; ns=$${repo#*=}; \
		kubectl get namespace "$$ns" >/dev/null 2>&1 && continue; \
		if kubectl get podvolumebackups -n velero -o jsonpath='{range .items[*]}{.spec.pod.namespace}{"\n"}{end}' | grep -qx "$$ns"; then \
			echo "$$name: namespace $$ns is gone but still referenced by backups, skipping"; \
		else \
			kubectl delete backuprepository -n velero "$$name"; \
		fi; \
	done

## --- Metrics (kube-state-metrics + node-exporter + Traefik NodePort), ---
## --- scraped by an external Prometheus on the LAN, no in-cluster Prometheus ---

monitoring:
	kubectl apply -k monitoring/
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics --version 8.4.2 \
		--namespace monitoring -f monitoring/kube-state-metrics-values.yaml
	helm upgrade --install node-exporter prometheus-community/prometheus-node-exporter --version 4.56.3 \
		--namespace monitoring -f monitoring/node-exporter-values.yaml

## --- Apps kept as plain Kustomize manifests (no official Helm chart) ---

arr:
	kubectl apply -k arr/

audiobookshelf:
	kubectl apply -k audiobookshelf/

jellyfin:
	kubectl apply -k jellyfin/

vaultwarden:
	kubectl apply -k vaultwarden/

## --- Apps deployed via their official Helm chart ---
## (namespace + supporting DB/Redis/Middleware manifests are applied first)

homarr:
	kubectl apply -k homarr/
	helm upgrade --install homarr oci://ghcr.io/homarr-labs/charts/homarr --version 8.28.2 \
		--namespace homarr -f homarr/values.yaml

immich:
	kubectl apply -k immich/
	helm repo add immich https://immich-app.github.io/immich-charts --force-update
	helm upgrade --install immich immich/immich --version 0.12.0 \
		--namespace immich -f immich/values.yaml

nextcloud:
	kubectl apply -k nextcloud/
	helm repo add nextcloud https://nextcloud.github.io/helm/ --force-update
	helm upgrade --install nextcloud nextcloud/nextcloud --version 9.2.6 \
		--namespace nextcloud -f nextcloud/values.yaml

all: traefik cert-manager clusterissuer velero monitoring arr audiobookshelf jellyfin vaultwarden homarr immich nextcloud
