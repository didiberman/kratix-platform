# Kratix IDP — Platform Engineering Demo

A fully automated Internal Developer Platform (IDP) built with **Kratix**, **Backstage**, **Flux**, **Crossplane**, and **MinIO** — deployed on a single-node k3s cluster on Hetzner Cloud.

One command spins up the entire stack from scratch.

---

## Architecture

```
Developer
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│  Backstage (Developer Portal)          kratix.yourdomain │
│  • Software Catalog                                      │
│  • Self-service Templates (nginx, postgres, etc.)        │
│  • Custom Kratix scaffolder actions                      │
└──────────────────┬──────────────────────────────────────┘
                   │ kratix:resourcerequest:create
                   ▼
┌──────────────────────────────────┐
│  Kratix (Platform Orchestrator)  │
│  • Promise CRDs                  │
│  • Pipeline Jobs (alpine:3.18)   │
│  • Writes manifests to MinIO     │
└──────────────────┬───────────────┘
                   │ writes YAML
                   ▼
┌──────────────────────────────┐
│  MinIO (State Store / S3)    │
│  kratix/platform-cluster/    │
│  backstage-catalog/nginx/    │
└──────────────────┬───────────┘
                   │ polls every 10s
                   ▼
┌──────────────────────────────────────────┐
│  Flux (GitOps Agent)                     │
│  Bucket source → Kustomization → apply   │
└──────────────────┬───────────────────────┘
                   │ kubectl apply
                   ▼
┌───────────────────────────────────┐
│  k3s Cluster (Hetzner CPX22)      │
│  • nginx Deployment + Service     │
│  • Crossplane (infra provisioner) │
│  • cert-manager (Let's Encrypt)   │
│  • Traefik (HTTPS ingress)        │
└───────────────────────────────────┘
```

### How the sync loop works

1. Developer submits a request via Backstage UI
2. Backstage calls `kratix:resourcerequest:create` → creates a `Nginx` CR in the cluster
3. Kratix detects the new CR and runs the **pipeline** (an alpine Job)
4. The pipeline generates a Deployment + Service YAML and writes it to **MinIO**
5. **Flux** polls MinIO every 10s and applies any new manifests to the cluster
6. The nginx pod is running — and Backstage automatically shows it in the Kubernetes tab

### Why this design (vs native Kratix SKE)

This repo uses community Kratix with a custom Backstage integration. The enterprise edition (SKE) ships with a pre-built Backstage plugin that auto-registers catalog entries for every Promise without custom scaffolder actions. This demo shows you how to wire it together manually — giving full visibility into every layer of the stack.

---

## Engineering Challenges

Building this stack required solving several non-obvious problems. Documenting them here because they took real debugging time and the solutions aren't obvious from the docs.

---

### 1. Flux never synced from MinIO — nothing ever deployed

**Symptom:** ResourceRequests were created, Kratix pipeline jobs completed successfully, manifests appeared in MinIO — but no Deployments or Services ever showed up in the cluster. `kubectl get pods -n default` stayed empty indefinitely.

**Root cause:** A race condition in the Kratix Destination controller. On startup, the `BucketStateStore` took a few seconds to reach `Ready`. During that window, the `Destination` controller tried to reconcile and found the state store "not ready" — so it aborted without creating the Flux `Bucket` source or `Kustomization`. Once the `BucketStateStore` became ready, the Destination re-reconciled and reported `Ready`, but in this version of Kratix it did **not** go back and create the Flux resources it had skipped. The Destination appeared healthy in `kubectl get destination` but had never wired up Flux at all.

The evidence was subtle: a `kratix-canary` object had been sitting in MinIO since early morning, but the corresponding `Namespace` never appeared in the cluster. Flux had no `Bucket` source to poll.

**Fix:** Manually create the Flux `Bucket` source and `Kustomization` pointing at the MinIO `kratix` bucket and `./platform-cluster` path:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: Bucket
metadata:
  name: kratix-platform-cluster
  namespace: flux-system
spec:
  provider: generic
  bucketName: kratix
  endpoint: minio.minio-system.svc.cluster.local:9000
  insecure: true
  interval: 10s
  secretRef:
    name: minio-credentials
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: kratix-platform-cluster
  namespace: flux-system
spec:
  interval: 10s
  path: ./platform-cluster
  prune: true
  sourceRef:
    kind: Bucket
    name: kratix-platform-cluster
```

Once applied, Flux immediately picked up the existing MinIO contents and applied everything within 10 seconds.

---

### 2. The API resource plural wasn't reaching the scaffolder action

**Symptom:** Submitting a form in Backstage produced a `404` from the Kubernetes API. The URL in the error was `/apis/workshop.kratix.io/v1alpha1/namespaces/default/nginxs` — the wrong plural. The correct plural registered by the CRD is `nginxes`.

**Initial approach:** Pass `plural: nginxes` as a template parameter and read it with `ctx.input.plural`. Despite the value being correct in the template YAML, it wasn't arriving in `ctx.input` at runtime — the field appeared undefined.

**Root cause:** Unclear, likely related to how the Backstage scaffolder TypeScript generics and input schema validation handled extra fields not explicitly declared in the action's Zod schema.

**Fix:** Removed the template parameter entirely and made the action discover the correct plural at runtime by calling the Kubernetes API discovery endpoint:

```typescript
async function discoverPlural(token, ca, group, version, kind) {
  const { data } = await k8sRequest(token, ca, "GET", `/apis/${group}/${version}`);
  const apiList = JSON.parse(data);
  const resource = apiList.resources.find(r => r.kind === kind);
  return resource?.name ?? kind.toLowerCase() + "s";
}
```

This is actually more robust than hardcoding — it works correctly for any Promise regardless of how its CRD defines the plural.

---

### 3. Malformed YAML from the pipeline — `serviceType` extracted as two lines

**Symptom:** The nginx pipeline produced a `Service` manifest with:

```yaml
type: {}
        NodePort
```

Instead of `type: NodePort`. The resulting YAML was unparseable and Flux reported apply errors.

**Root cause:** The pipeline script used `grep 'serviceType:' /kratix/input/object.yaml` to extract the service type. This matched **two** lines — once in the `spec` section (`  serviceType: NodePort`) and once in `managedFields` where Kubernetes stores field ownership metadata (`f:serviceType: {}`). The variable `TYPE` became a two-line string, and when interpolated into the YAML template it produced broken output.

**Fix:** Replace `grep` with `awk` scoped to fire only after the `spec:` line is found, and exit immediately after the first match:

```bash
TYPE=$(awk '/^spec:/{found=1} found && /serviceType:/{print $2; exit}' /kratix/input/object.yaml)
```

This reads `serviceType` exclusively from within the spec block, completely ignoring `managedFields`.

---

### 4. MinIO PUT returning 403 — wrong auth mechanism

**Symptom:** The `kratix:catalog:register` scaffolder action returned HTTP 400/403 when trying to write catalog YAML to MinIO. The MinIO credentials were correct.

**Root cause:** Node.js `http.request` with the `auth: 'user:password'` option sends an HTTP `Authorization: Basic ...` header. MinIO's S3-compatible API does **not** accept Basic auth — it requires AWS Signature Version 4. The request was being rejected as unauthenticated regardless of the credentials.

**Fix:** Rather than implement AWS SigV4 signing from scratch inside the scaffolder action, set the `backstage-catalog` bucket to fully public:

```bash
mc anonymous set public local/backstage-catalog
```

This allows anonymous `GET` and `PUT` requests, which is acceptable for a demo catalog store (the contents are non-sensitive catalog YAML files). The `minioRequest()` function was updated to send no auth header at all.

---

### 5. Backstage `catalog:register` returning 400 — host not in allowlist

**Symptom:** The final step of the Backstage scaffolder — the built-in `catalog:register` action — returned HTTP 400 with "URL not allowed" even though the MinIO bucket was now public and the URL was reachable.

**Root cause (first attempt):** The Backstage backend had no `backend.reading.allow` configuration, so all external URLs were blocked by default.

**Root cause (second attempt):** After adding `host: minio.minio-system.svc.cluster.local` to `reading.allow`, it still failed. The Backstage URL allowlist checks include the port when the URL uses a non-standard port. Since the MinIO URL was `http://minio.minio-system.svc.cluster.local:9000/...`, the host string evaluated against the allowlist was `minio.minio-system.svc.cluster.local:9000` — not just the hostname.

**Fix:** Qualify the allowlist entry with the port:

```yaml
backend:
  reading:
    allow:
      - host: minio.minio-system.svc.cluster.local:9000
```

---

### 6. Backstage Kubernetes plugin showing "there was a problem" despite resources being visible

**Symptom:** The Kubernetes tab on a catalog Component showed the pod, deployment, and service correctly, but displayed a yellow warning banner: *"There was a problem retrieving Kubernetes objects."*

**Root cause:** The Backstage service account (`backstage` SA in the `backstage` namespace) had RBAC permissions only for the core resources (`pods`, `services`, `deployments`). The Kubernetes plugin queries many additional resource types on every page load — `ingresses`, `jobs`, `cronjobs`, `horizontalpodautoscalers`, `limitranges`, `resourcequotas`, and pod metrics. Each forbidden request returned HTTP 403 and the plugin surfaced them as a collective warning even though the primary resources loaded fine.

**Fix:** Expand the `ClusterRole` to cover all resource types the plugin queries:

```yaml
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["batch"]
  resources: ["jobs", "cronjobs"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["autoscaling"]
  resources: ["horizontalpodautoscalers"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["metrics.k8s.io"]
  resources: ["pods", "nodes"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["limitranges", "resourcequotas", "events"]
  verbs: ["get", "list", "watch"]
```

---

### 7. Kubernetes plugin couldn't find resources even with correct labels

**Symptom:** After fixing the RBAC, the Kubernetes tab still showed nothing for a provisioned nginx instance. The pod and service existed in `default` but weren't appearing.

**Root cause:** Flux's `Kustomization` controller strips and rewrites labels when it applies manifests. The `backstage.io/kubernetes-id` label written by the Kratix pipeline was being removed during Flux apply, so the plugin's label selector found nothing.

**Fix:** Move the label into every resource that Flux would manage — the `Deployment` metadata, the `Service` metadata, **and** the Pod template labels inside the Deployment spec. Pod template labels survive because they're part of the pod spec, not top-level resource metadata:

```yaml
metadata:
  labels:
    app: my-app-nginx
    backstage.io/kubernetes-id: my-app-nginx   # on Deployment
spec:
  template:
    metadata:
      labels:
        app: my-app-nginx
        backstage.io/kubernetes-id: my-app-nginx  # on Pod template — survives Flux
```

Since the Kubernetes plugin locates pods by label, and pods inherit their labels from the template, this ensured the plugin could always find the running pods regardless of what Flux did to the Deployment's own metadata.

---

### 8. Docker build failing with `exit code 2` on `tar xzf bundle.tar.gz`

**Symptom:** `docker build` failed during the `RUN tar xzf skeleton.tar.gz` step with a permissions error: `can't create directory 'packages/': Permission denied`.

**Root cause:** Docker BuildKit was not enabled. Without BuildKit, the `WORKDIR /app` instruction creates the directory as `root`. The Dockerfile then switches to the `node` user — but the `tar` command can't write into a root-owned directory.

**Fix:**

```bash
DOCKER_BUILDKIT=1 docker build packages/backend -f packages/backend/Dockerfile -t kratix-portal:latest .
```

With BuildKit enabled, the WORKDIR is created with the correct ownership for the `node` user before `tar` runs.

---

## Prerequisites

| Tool | Version |
|------|---------|
| Terraform | ≥ 1.5 |
| Helm | ≥ 3.12 |
| kubectl | any |
| rsync | any (usually pre-installed) |
| A Hetzner Cloud account | — |
| A domain on Cloudflare DNS | — |

---

## Quick Start

### 1. Clone and configure secrets

```bash
git clone https://github.com/yourusername/kratix-idp
cd kratix-idp
cp secrets.example.env secrets.env
```

Edit `secrets.env`:

```env
HCLOUD_TOKEN=your-hetzner-api-token
CLOUDFLARE_TOKEN=your-cloudflare-api-token  # Zone:DNS:Edit permission
DOMAIN=kratix.yourdomain.com                # must be on Cloudflare
SSH_PUBLIC_KEY_PATH=~/.ssh/id_rsa.pub
SSH_PRIVATE_KEY_PATH=~/.ssh/id_rsa
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=minioadmin
POSTGRES_PASSWORD=backstage
```

### 2. Point DNS at your server

After `make infra`, point an A record for your domain at the server IP output:

```bash
make infra
# → server_ip = 1.2.3.4
# Add DNS: kratix.yourdomain.com → 1.2.3.4
```

### 3. Deploy everything

```bash
make all
```

This runs 5 steps (~20 minutes total):

| Step | What it does | Time |
|------|-------------|------|
| `infra` | Terraform: Hetzner server + firewall | ~1 min |
| `bootstrap` | SSH: k3s, Helm, MinIO, Kratix, Flux, Traefik | ~8 min |
| `build-backstage` | SSH: create Backstage app + build Docker image | ~10 min |
| `manifests` | kubectl: RBAC, TLS cert, Backstage Helm, Flux config | ~3 min |
| `promises` | kubectl: apply nginx Promise | ~30s |

### 4. Open the portal

```
https://kratix.yourdomain.com
```

It may take 2-3 minutes for the Let's Encrypt certificate to be issued on first deploy.

---

## Demo: Self-Service nginx

1. Go to **Create** in Backstage
2. Choose **"Request Nginx Instance"**
3. Enter a name (e.g. `my-app`) and select `NodePort`
4. Click **Create**

Behind the scenes:
- Kratix creates an `Nginx` CR
- Pipeline job generates the Deployment + Service YAML
- Writes to MinIO → Flux applies to cluster within 10s
- Component appears in Backstage catalog with Kubernetes resources visible

To access the nginx instance directly:
```bash
kubectl get svc -n default my-app-nginx
# → NodePort on 30xxx
# curl http://<server-ip>:<nodeport>
```

---

## Demo: Promise Upgrade (Fleet Management)

Change the nginx version in `promises/nginx.yaml` (e.g. `nginx:1.26` → `nginx:1.27`):

```bash
kubectl apply -f promises/nginx.yaml
```

Kratix automatically **re-runs the pipeline** on every existing instance. All running nginx pods update without touching any ResourceRequests. This is the core value of the Promise model — operators own the upgrade path.

---

## Repo Structure

```
.
├── Makefile                    # Deploy orchestrator
├── secrets.example.env         # Template for required secrets
│
├── terraform/                  # Hetzner server + firewall
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
│
├── scripts/
│   ├── bootstrap.sh            # Runs on server: k3s + all Helm charts
│   ├── build-backstage.sh      # Runs on server: create app + build image
│   └── post-deploy.sh          # Runs locally: manifests + Helm + Promise
│
├── k8s/                        # Kubernetes manifests (applied in order)
│   ├── 01-cert-issuer.yaml     # Let's Encrypt ClusterIssuer (Cloudflare DNS-01)
│   ├── 02-kratix-config.yaml   # BucketStateStore + Destination
│   ├── 03-flux-kratix.yaml     # Flux Bucket source + Kustomization
│   ├── 04-backstage-rbac.yaml  # ServiceAccount + ClusterRole
│   └── 05-backstage-tls.yaml   # Certificate + Traefik IngressRoute
│
├── promises/
│   └── nginx.yaml              # Kratix nginx Promise (upgradeable fleet)
│
└── backstage/                  # Custom Backstage additions only
    ├── packages/backend/src/
    │   ├── index.ts            # Registers kratix module
    │   └── kratixModule.ts     # Custom scaffolder actions
    └── examples/
        ├── nginx-promise-template.yaml   # Provision + delete templates
        └── platform-components.yaml     # Catalog: Kratix, Flux, Crossplane
```

---

## Custom Backstage Actions

Three scaffolder actions in `backstage/packages/backend/src/kratixModule.ts`:

| Action | Description |
|--------|-------------|
| `kratix:resourcerequest:create` | Creates a Kratix CR (auto-discovers plural via API) |
| `kratix:resourcerequest:delete` | Deletes the CR and removes the MinIO catalog entry |
| `kratix:catalog:register` | Writes a catalog-info.yaml to MinIO (publicly accessible) |

The built-in `catalog:register` action then reads the MinIO URL and registers the entity — no GitHub required.

---

## Stack Versions

| Component | Version |
|-----------|---------|
| k3s | latest |
| cert-manager | v1.20.2 |
| MinIO | RELEASE.2024-12-18 |
| Crossplane | 2.3.1 |
| Kratix | latest |
| Flux | latest |
| Backstage | 1.51+ |
| Traefik | v3.x (k3s default) |

---

## Teardown

```bash
make teardown
```

Destroys the Hetzner server and firewall. Nothing remains.

---

## Cost

Hetzner CPX22: ~**€8/month** (or ~€0.02/hour if you destroy after the demo).
