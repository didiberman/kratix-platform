-include secrets.env
export

SSH_KEY         ?= ~/.ssh/id_rsa
SSH_OPTS        := -o StrictHostKeyChecking=no -o ConnectTimeout=10
SERVER_IP       ?= $(shell terraform -chdir=terraform output -raw server_ip 2>/dev/null)
KUBECONFIG_PATH := $(CURDIR)/kubeconfig.yaml

.PHONY: all infra wait-ssh bootstrap build-backstage kubeconfig manifests promises deploy teardown status

## Full deployment from scratch
all: infra wait-ssh bootstrap build-backstage kubeconfig manifests promises
	@echo ""
	@echo "✅  Kratix IDP stack deployed!"
	@echo "    Portal:     https://$(DOMAIN)"
	@echo "    Server IP:  $(SERVER_IP)"
	@echo "    kubeconfig: $(KUBECONFIG_PATH)"

## Step 1 — Provision Hetzner server + Cloudflare DNS record
infra:
	@test -n "$(HCLOUD_TOKEN)" || (echo "ERROR: HCLOUD_TOKEN not set. Copy secrets.example.env → secrets.env and fill in values." && exit 1)
	@test -n "$(CLOUDFLARE_TOKEN)" || (echo "ERROR: CLOUDFLARE_TOKEN not set." && exit 1)
	@test -n "$(DOMAIN)" || (echo "ERROR: DOMAIN not set." && exit 1)
	terraform -chdir=terraform init -upgrade -input=false
	terraform -chdir=terraform apply -auto-approve \
	  -var="hcloud_token=$(HCLOUD_TOKEN)" \
	  -var="cloudflare_token=$(CLOUDFLARE_TOKEN)" \
	  -var="domain=$(DOMAIN)" \
	  -var="ssh_public_key_path=$(SSH_PUBLIC_KEY_PATH)"

## Wait until SSH is reachable (cloud-init takes ~30s)
wait-ssh:
	@echo "Waiting for SSH on $(SERVER_IP)..."
	@until ssh $(SSH_OPTS) -i $(SSH_KEY) root@$(SERVER_IP) exit 2>/dev/null; do \
	  printf "."; sleep 5; \
	done
	@echo " ready"

## Step 2 — Install k3s + all platform components on the server
bootstrap:
	ssh $(SSH_OPTS) -i $(SSH_KEY) root@$(SERVER_IP) \
	  "DOMAIN='$(DOMAIN)' MINIO_ROOT_USER='$(MINIO_ROOT_USER)' MINIO_ROOT_PASSWORD='$(MINIO_ROOT_PASSWORD)' bash -s" \
	  < scripts/bootstrap.sh

## Step 3 — Sync Backstage source + build Docker image on the server
build-backstage:
	@echo "Syncing Backstage source to server..."
	ssh $(SSH_OPTS) -i $(SSH_KEY) root@$(SERVER_IP) "mkdir -p /opt/iac/backstage"
	rsync -av -e "ssh $(SSH_OPTS) -i $(SSH_KEY)" \
	  backstage/ root@$(SERVER_IP):/opt/iac/backstage/
	@echo "Building Backstage image on server (takes ~10 minutes first time)..."
	ssh $(SSH_OPTS) -i $(SSH_KEY) root@$(SERVER_IP) bash < scripts/build-backstage.sh

## Fetch kubeconfig from server (replaces server-internal IP with public IP)
kubeconfig:
	@echo "Fetching kubeconfig..."
	ssh $(SSH_OPTS) -i $(SSH_KEY) root@$(SERVER_IP) \
	  "cat /etc/rancher/k3s/k3s.yaml" \
	  | sed "s|127.0.0.1|$(SERVER_IP)|g" \
	  > $(KUBECONFIG_PATH)
	@echo "kubeconfig saved to $(KUBECONFIG_PATH)"

## Step 4 — Apply all Kubernetes manifests, install Backstage, load Promise
manifests: kubeconfig
	DOMAIN="$(DOMAIN)" \
	CLOUDFLARE_TOKEN="$(CLOUDFLARE_TOKEN)" \
	MINIO_ROOT_USER="$(MINIO_ROOT_USER)" \
	MINIO_ROOT_PASSWORD="$(MINIO_ROOT_PASSWORD)" \
	POSTGRES_PASSWORD="$(POSTGRES_PASSWORD)" \
	  bash scripts/post-deploy.sh

## Alias — promises are applied inside post-deploy.sh as part of manifests
promises: manifests

## Show cluster status
status:
	@KUBECONFIG=$(KUBECONFIG_PATH) kubectl get pods -A

## Destroy everything (server + firewall + DNS record)
teardown:
	terraform -chdir=terraform destroy -auto-approve \
	  -var="hcloud_token=$(HCLOUD_TOKEN)" \
	  -var="cloudflare_token=$(CLOUDFLARE_TOKEN)" \
	  -var="domain=$(DOMAIN)" \
	  -var="ssh_public_key_path=$(SSH_PUBLIC_KEY_PATH)"
	rm -f $(KUBECONFIG_PATH)
