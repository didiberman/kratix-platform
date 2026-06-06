#!/usr/bin/env bash
# Runs locally via kubectl. Applies all k8s manifests in order, then installs
# Backstage via Helm and loads the nginx Promise.
set -euo pipefail

log() { echo "[post-deploy] $*"; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

: "${DOMAIN:?DOMAIN is required}"
: "${CLOUDFLARE_TOKEN:?CLOUDFLARE_TOKEN is required}"
: "${MINIO_ROOT_USER:=minioadmin}"
: "${MINIO_ROOT_PASSWORD:=minioadmin}"
: "${POSTGRES_PASSWORD:=backstage}"

export KUBECONFIG="${ROOT_DIR}/kubeconfig.yaml"

wait_for_crd() {
  local crd="$1"
  log "Waiting for CRD $crd..."
  until kubectl get crd "$crd" &>/dev/null; do sleep 3; done
}

# ── 1. Cloudflare secret for cert-manager ────────────────────────────────────
log "Creating Cloudflare API token secret..."
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token="$CLOUDFLARE_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── 2. ClusterIssuer (Let's Encrypt + Cloudflare DNS-01) ────────────────────
log "Applying ClusterIssuer..."
sed "s/__EMAIL__/$(git config user.email 2>/dev/null || echo admin@example.com)/" \
  "$ROOT_DIR/k8s/01-cert-issuer.yaml" | kubectl apply -f -

# ── 3. Kratix state store + destination ──────────────────────────────────────
log "Applying Kratix config..."
kubectl apply -f "$ROOT_DIR/k8s/02-kratix-config.yaml"

# Wait for BucketStateStore to be ready
wait_for_crd "bucketstatestores.platform.kratix.io"
until kubectl get bucketstatestore default 2>/dev/null | grep -q "True"; do sleep 3; done

# ── 4. Backstage RBAC (SA + ClusterRole) ─────────────────────────────────────
log "Applying Backstage RBAC..."
kubectl apply -f "$ROOT_DIR/k8s/04-backstage-rbac.yaml"

# Wait for SA token to be populated
log "Waiting for SA token..."
until kubectl get secret backstage-sa-token -n backstage \
  -o jsonpath='{.data.token}' 2>/dev/null | grep -q "."; do sleep 2; done

SA_TOKEN=$(kubectl get secret backstage-sa-token -n backstage \
  -o jsonpath='{.data.token}' | base64 --decode)
CA_DATA=$(kubectl get secret backstage-sa-token -n backstage \
  -o jsonpath='{.data.ca\.crt}')

# ── 5. Backstage TLS (Certificate + Middleware + IngressRoute) ───────────────
log "Applying Backstage TLS resources..."
sed "s/__DOMAIN__/${DOMAIN}/g" "$ROOT_DIR/k8s/05-backstage-tls.yaml" | kubectl apply -f -

# ── 6. Backstage Helm install ────────────────────────────────────────────────
log "Installing Backstage via Helm..."

BACKSTAGE_CONFIGMAP=$(cat <<EOF
app:
  title: Kratix Platform Portal
  baseUrl: https://${DOMAIN}
backend:
  baseUrl: https://${DOMAIN}
  reading:
    allow:
      - host: minio.minio-system.svc.cluster.local:9000
  cors:
    origin: https://${DOMAIN}
    methods: [GET, HEAD, PATCH, POST, PUT, DELETE]
    credentials: true
  csp:
    upgrade-insecure-requests: false
    connect-src: ["'self'", 'http:', 'https:']
  database:
    client: pg
    connection:
      host: backstage-postgresql
      port: 5432
      user: bn_backstage
      password: \${POSTGRES_PASSWORD}
auth:
  environment: production
  providers:
    guest:
      dangerouslyAllowOutsideDevelopment: true
techdocs:
  builder: local
  generator:
    runIn: local
  publisher:
    type: local
catalog:
  rules:
    - allow: [Component, System, API, Resource, Location, User, Group]
  locations:
    - type: file
      target: /app/examples/org.yaml
      rules:
        - allow: [User, Group]
    - type: file
      target: /app/examples/platform-components.yaml
      rules:
        - allow: [Component, System, API, Resource]
    - type: file
      target: /app/examples/nginx-promise-template.yaml
      rules:
        - allow: [Component, Template]
kubernetes:
  serviceLocatorMethod:
    type: multiTenant
  clusterLocatorMethods:
    - type: config
      clusters:
        - url: https://kubernetes.default.svc
          name: platform-cluster
          authProvider: serviceAccount
          serviceAccountToken: ${SA_TOKEN}
          caData: ${CA_DATA}
          customResources:
            - group: workshop.kratix.io
              apiVersion: v1alpha1
              plural: nginxes
EOF
)

kubectl create namespace backstage --dry-run=client -o yaml | kubectl apply -f -

# Use a distinct name so it never conflicts with the Helm-managed backstage-app-config
# ConfigMap that the Backstage chart creates from backstage.appConfig.* values.
kubectl create configmap kratix-backstage-extra \
  --namespace backstage \
  --from-literal=app-config.extra.yaml="$BACKSTAGE_CONFIGMAP" \
  --dry-run=client -o yaml | kubectl apply -f -

# If there is a failed Helm release, tear it down first.
if helm status backstage -n backstage &>/dev/null 2>&1; then
  HELM_STATUS=$(helm status backstage -n backstage -o json | python3 -c "import json,sys; print(json.load(sys.stdin)['info']['status'])")
  if [ "$HELM_STATUS" = "failed" ]; then
    log "Cleaning up failed Backstage Helm release..."
    helm uninstall backstage -n backstage --ignore-not-found || true
  fi
fi

# Pre-create the backstage-postgresql secret with the exact key names the Bitnami
# chart expects ("user-password" and "postgres-password"). The chart only creates
# the secret when it doesn't already exist, so pre-creating ensures the keys are
# consistent across installs and upgrades — avoiding the "user-password not found"
# error caused by chart version differences.
kubectl delete secret backstage-postgresql -n backstage --ignore-not-found || true
kubectl delete pvc --selector='app.kubernetes.io/instance=backstage' -n backstage --ignore-not-found || true
kubectl create secret generic backstage-postgresql \
  --namespace backstage \
  --from-literal=user-password="${POSTGRES_PASSWORD}" \
  --from-literal=postgres-password="${POSTGRES_PASSWORD}"

helm upgrade --install backstage backstage/backstage \
  --namespace backstage \
  --set backstage.image.registry=docker.io \
  --set backstage.image.repository=library/kratix-portal \
  --set backstage.image.tag=latest \
  --set backstage.image.pullPolicy=IfNotPresent \
  --set backstage.appConfig.app.baseUrl="https://${DOMAIN}" \
  --set backstage.appConfig.backend.baseUrl="https://${DOMAIN}" \
  --set backstage.appConfig.backend.cors.origin="https://${DOMAIN}" \
  --set postgresql.enabled=true \
  --set postgresql.auth.existingSecret=backstage-postgresql \
  --set postgresql.auth.secretKeys.userPasswordKey=user-password \
  --set postgresql.auth.secretKeys.adminPasswordKey=postgres-password \
  --set "backstage.extraVolumes[0].name=kratix-extra-config" \
  --set "backstage.extraVolumes[0].configMap.name=kratix-backstage-extra" \
  --set "backstage.extraVolumeMounts[0].name=kratix-extra-config" \
  --set "backstage.extraVolumeMounts[0].mountPath=/app/app-config.extra.yaml" \
  --set "backstage.extraVolumeMounts[0].subPath=app-config.extra.yaml" \
  --set "backstage.args[0]=--config" \
  --set "backstage.args[1]=app-config.yaml" \
  --set "backstage.args[2]=--config" \
  --set "backstage.args[3]=/app/app-config.extra.yaml" \
  --wait

# ── 7. Flux bucket source for Kratix ─────────────────────────────────────────
log "Applying Flux resources for Kratix..."
kubectl apply -f "$ROOT_DIR/k8s/03-flux-kratix.yaml"

# ── 8. Apply nginx Promise ────────────────────────────────────────────────────
log "Applying nginx Promise..."
wait_for_crd "promises.platform.kratix.io"
kubectl apply -f "$ROOT_DIR/promises/nginx.yaml"
until kubectl get promise nginx 2>/dev/null | grep -q "Available"; do sleep 5; done

log "
✅ Deployment complete!
   Backstage: https://${DOMAIN}

   It may take 2-3 minutes for the TLS certificate to be issued by Let's Encrypt.
   To check: kubectl get certificate kratix-tls -n backstage
"
