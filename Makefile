.PHONY: help cert-manager clusterissuer velero arr audiobookshelf dokuwiki jellyfin vaultwarden paperless-ngx homarr immich nextcloud all

help:
	@echo "Platform:      make cert-manager clusterissuer velero"
	@echo "Raw manifests: make arr audiobookshelf dokuwiki jellyfin vaultwarden paperless-ngx"
	@echo "Helm apps:     make homarr immich nextcloud"
	@echo "Everything:    make all"
	@echo ""
	@echo "Secrets are NOT applied automatically. Copy the matching file(s) from"
	@echo "secrets/*.yaml.example, fill in real values, and 'kubectl apply -f' them"
	@echo "before (or right after) deploying the app that needs them."

## --- Platform (not built into k3s) ---

cert-manager:
	helm repo add jetstack https://charts.jetstack.io --force-update
	helm upgrade --install cert-manager jetstack/cert-manager \
		--namespace cert-manager --create-namespace \
		--set crds.enabled=true

clusterissuer:
	kubectl apply -f cert-manager/clusterissuer.yaml

## --- Backups (Velero, backed by RustFS/S3 on the TrueNAS box) ---

velero:
	helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts --force-update
	helm upgrade --install velero vmware-tanzu/velero \
		--namespace velero --create-namespace \
		-f velero/values.yaml

## --- Apps kept as plain Kustomize manifests (no official Helm chart) ---

arr:
	kubectl apply -k arr/

audiobookshelf:
	kubectl apply -k audiobookshelf/

dokuwiki:
	kubectl apply -k dokuwiki/

jellyfin:
	kubectl apply -k jellyfin/

vaultwarden:
	kubectl apply -k vaultwarden/

paperless-ngx:
	kubectl apply -k paperless-ngx/

## --- Apps deployed via their official Helm chart ---
## (namespace + supporting DB/Redis/Middleware manifests are applied first)

homarr:
	kubectl create namespace homarr --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install homarr oci://ghcr.io/homarr-labs/charts/homarr \
		--namespace homarr -f homarr/values.yaml

immich:
	kubectl apply -k immich/
	helm repo add immich https://immich-app.github.io/immich-charts --force-update
	helm upgrade --install immich immich/immich \
		--namespace immich -f immich/values.yaml

nextcloud:
	kubectl apply -k nextcloud/
	helm repo add nextcloud https://nextcloud.github.io/helm/ --force-update
	helm upgrade --install nextcloud nextcloud/nextcloud \
		--namespace nextcloud -f nextcloud/values.yaml

all: cert-manager clusterissuer velero arr audiobookshelf dokuwiki jellyfin vaultwarden paperless-ngx homarr immich nextcloud
