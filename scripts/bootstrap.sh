#!/usr/bin/env bash
# Runs on the Hetzner server. Installs k3s + all platform components.
# Called by: make bootstrap
set -euo pipefail

log() { echo "[bootstrap] $*"; }

# ── Environment (passed in by Makefile via ssh env) ────────────────────────
DOMAIN="${DOMAIN:?DOMAIN is required}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-backstage}"

# ── Dependencies ────────────────────────────────────────────────────────────
log "Installing system dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git docker.io jq

# ── k3s ─────────────────────────────────────────────────────────────────────
if ! command -v k3s &>/dev/null; then
  log "Installing k3s..."
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable=traefik" sh -
  # Wait for node to be ready
  until k3s kubectl get nodes 2>/dev/null | grep -q " Ready"; do sleep 3; done
  log "k3s ready"
else
  log "k3s already installed"
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# ── Helm ────────────────────────────────────────────────────────────────────
if ! command -v helm &>/dev/null; then
  log "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# ── Helm repos ───────────────────────────────────────────────────────────────
log "Adding Helm repos..."
helm repo add jetstack       https://charts.jetstack.io            --force-update
helm repo add minio          https://charts.min.io                 --force-update
helm repo add crossplane     https://charts.crossplane.io/stable   --force-update
helm repo add backstage      https://backstage.github.io/charts    --force-update
helm repo update

# ── cert-manager ─────────────────────────────────────────────────────────────
log "Installing cert-manager..."
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.20.2 \
  --set crds.enabled=true \
  --wait

# ── MinIO ────────────────────────────────────────────────────────────────────
log "Installing MinIO..."
helm upgrade --install minio minio/minio \
  --namespace minio-system --create-namespace \
  --set rootUser="${MINIO_ROOT_USER}" \
  --set rootPassword="${MINIO_ROOT_PASSWORD}" \
  --set mode=standalone \
  --set replicas=1 \
  --set persistence.size=5Gi \
  --set resources.requests.memory=256Mi \
  --set service.type=ClusterIP \
  --wait

# ── Install mc (MinIO client) and set up buckets ──────────────────────────────
log "Setting up MinIO buckets..."
if ! command -v mc &>/dev/null; then
  curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc
  chmod +x /usr/local/bin/mc
fi
MINIO_POD=$(kubectl get pod -n minio-system -l app=minio -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n minio-system "$MINIO_POD" -- sh -c "
  mc alias set local http://localhost:9000 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD} &&
  mc mb --ignore-existing local/kratix &&
  mc mb --ignore-existing local/backstage-catalog &&
  mc anonymous set public local/backstage-catalog
"

# ── Crossplane ───────────────────────────────────────────────────────────────
log "Installing Crossplane..."
helm upgrade --install crossplane crossplane/crossplane \
  --namespace crossplane-system --create-namespace \
  --version 2.3.1 \
  --wait

# ── Kratix ───────────────────────────────────────────────────────────────────
log "Installing Kratix..."
kubectl apply --server-side -f https://github.com/syntasso/kratix/releases/latest/download/kratix.yaml
until kubectl get deployment -n kratix-platform-system kratix-platform-controller-manager 2>/dev/null | grep -q "1/1"; do sleep 5; done
log "Kratix ready"

# ── Flux ─────────────────────────────────────────────────────────────────────
log "Installing Flux..."
kubectl apply --server-side -f https://github.com/fluxcd/flux2/releases/latest/download/install.yaml
until kubectl get deployment -n flux-system source-controller 2>/dev/null | grep -q "1/1"; do sleep 5; done
log "Flux ready"

# ── Traefik ───────────────────────────────────────────────────────────────────
log "Installing Traefik..."
helm upgrade --install traefik-crd \
  oci://ghcr.io/traefik/helm/traefik \
  --namespace kube-system \
  --set crds.enabled=true \
  --wait || true

helm upgrade --install traefik \
  oci://ghcr.io/traefik/helm/traefik \
  --namespace kube-system \
  --set service.type=LoadBalancer \
  --wait

# ── Export kubeconfig ─────────────────────────────────────────────────────────
log "Exporting kubeconfig..."
cat /etc/rancher/k3s/k3s.yaml

log "Bootstrap complete ✓"
