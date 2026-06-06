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
