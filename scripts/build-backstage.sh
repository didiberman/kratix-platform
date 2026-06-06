#!/usr/bin/env bash
# Runs on the Hetzner server. Creates Backstage app from scratch, applies
# our customizations, and builds the Docker image.
# Called by: make build-backstage (after rsync of backstage/ directory)
set -euo pipefail

log() { echo "[backstage-build] $*"; }

INSTALL_DIR="/opt/kratix-portal"
CUSTOM_SRC="/opt/iac/backstage"

# ── Node.js 20 LTS ────────────────────────────────────────────────────────────
if ! node --version 2>/dev/null | grep -q "^v20\|^v22"; then
  log "Installing Node.js 20 LTS..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y -qq nodejs
fi

# ── Build tools (required by node-gyp for native modules) ────────────────────
log "Ensuring build tools are present..."
apt-get install -y -qq build-essential python3 python-is-python3 ca-certificates curl

# ── Docker buildx plugin (required by Backstage Dockerfile which uses BuildKit) ─
if ! docker buildx version &>/dev/null 2>&1; then
  log "Installing docker-buildx-plugin..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-buildx-plugin
fi

# ── Yarn ──────────────────────────────────────────────────────────────────────
if ! command -v yarn &>/dev/null; then
  log "Installing Yarn..."
  corepack enable
  corepack prepare yarn@stable --activate
fi

# ── Create Backstage app (skip if already exists) ─────────────────────────────
if [ ! -d "$INSTALL_DIR" ]; then
  log "Creating Backstage app at $INSTALL_DIR (this takes 2-3 minutes)..."
  CI=true npx --yes @backstage/create-app@latest \
    --path "$INSTALL_DIR" \
    --skip-install
  log "Backstage scaffold created"
else
  log "Backstage app already exists at $INSTALL_DIR"
fi

# ── Apply our customizations ───────────────────────────────────────────────────
log "Applying customizations..."
cp "$CUSTOM_SRC/packages/backend/src/index.ts"      "$INSTALL_DIR/packages/backend/src/index.ts"
cp "$CUSTOM_SRC/packages/backend/src/kratixModule.ts" "$INSTALL_DIR/packages/backend/src/kratixModule.ts"
cp "$CUSTOM_SRC/examples/nginx-promise-template.yaml" "$INSTALL_DIR/examples/nginx-promise-template.yaml"
cp "$CUSTOM_SRC/examples/platform-components.yaml"   "$INSTALL_DIR/examples/platform-components.yaml"

# ── Add kubernetes backend plugin to backend package.json ────────────────────
log "Ensuring kubernetes backend plugin is in package.json..."
cd "$INSTALL_DIR"
node -e "
  const fs = require('fs');
  const path = 'packages/backend/package.json';
  const pkg = JSON.parse(fs.readFileSync(path, 'utf8'));
  const deps = {
    '@backstage/plugin-kubernetes-backend': '^0.21.4',
    '@backstage/plugin-notifications-backend': '^0.6.5',
    '@backstage/plugin-signals-backend': '^0.3.15',
  };
  let changed = false;
  for (const [k, v] of Object.entries(deps)) {
    if (!pkg.dependencies[k]) { pkg.dependencies[k] = v; changed = true; }
  }
  if (changed) {
    fs.writeFileSync(path, JSON.stringify(pkg, null, 2) + '\n');
    console.log('Updated package.json with missing plugins');
  } else {
    console.log('package.json already has all required plugins');
  }
"

# ── Skip isolated-vm native build ────────────────────────────────────────────
# isolated-vm@6.x uses a V8 SourceLocation API removed in newer Node.js 20
# builds. In Yarn 4, native builds are skipped via dependenciesMeta in
# package.json. Backstage falls back to Node's built-in vm module when the
# native addon is absent.
node -e "
  const fs = require('fs');
  const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
  pkg.dependenciesMeta = pkg.dependenciesMeta || {};
  pkg.dependenciesMeta['isolated-vm'] = { built: false };
  fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
"

# ── Install dependencies ──────────────────────────────────────────────────────
log "Installing dependencies (this takes 3-5 minutes)..."
yarn install 2>&1 | tail -30

# ── Build ─────────────────────────────────────────────────────────────────────
log "Building TypeScript..."
yarn tsc 2>&1 | tail -5

log "Building backend bundle..."
yarn build:backend 2>&1 | tail -10

# ── Build Docker image ────────────────────────────────────────────────────────
log "Building Docker image kratix-portal:latest..."
docker build . \
  -f packages/backend/Dockerfile \
  --tag kratix-portal:latest

log "Docker image built ✓"
docker images kratix-portal:latest

# k3s uses containerd, not the Docker daemon. Import the image so k3s can use
# it without pulling from a registry.
log "Importing image into k3s containerd..."
docker save kratix-portal:latest | k3s ctr images import -
log "Image available in containerd ✓"
