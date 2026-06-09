#!/usr/bin/env bash
# Provision the workshop cluster: k3d -> Gateway API CRDs -> Traefik (Gateway provider)
# -> CloudNativePG -> build & load the image. Runnable from anywhere.
# After this, deploy the app with:  kubectl apply -k k8s/base
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # dev/k8s
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"                 # repo root (Dockerfile + k8s/)

echo "Installing k3d . . ."
if ! command -v k3d >/dev/null 2>&1; then
  wget -q -O - https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi

echo "Creating cluster 'tethys' . . ."
mkdir -p "$HOME/k3d/tethys-storage"
if k3d cluster list 2>/dev/null | grep -q '^tethys'; then
  echo "  cluster 'tethys' already exists, skipping create"
else
  k3d cluster create tethys \
    --servers 1 \
    --agents 1 \
    --k3s-arg "--disable=traefik@server:0" \
    -p "8080:80@loadbalancer" \
    -p "8443:443@loadbalancer" \
    --volume "$HOME/k3d/tethys-storage:/var/lib/rancher/k3s/storage@all"
fi

echo "Waiting for nodes to be ready . . ."
kubectl wait --for=condition=Ready nodes --all --timeout=120s
echo "Cluster is ready!"

# Gateway API ships CRDs ONLY (no controller) -- the controller is Traefik, installed below.
echo "Installing Gateway API CRDs . . ."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
echo "Waiting for the CRDs to be established . . ."
kubectl wait --for=condition=established --timeout=60s \
  crd/gateways.gateway.networking.k8s.io \
  crd/gatewayclasses.gateway.networking.k8s.io \
  crd/httproutes.gateway.networking.k8s.io
echo "Gateway API CRDs are ready!"

echo "Installing Traefik (with the Gateway API provider enabled) . . ."
helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install traefik traefik/traefik \
  --namespace traefik --create-namespace \
  -f "$SCRIPT_DIR/traefik-values.yaml"
kubectl -n traefik rollout status deployment/traefik --timeout=180s
echo "Traefik is ready!"

echo "Installing CloudNativePG . . ."
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.29/releases/cnpg-1.29.1.yaml
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=180s
echo "CloudNativePG controller is ready!"

echo "Building the Tethys image . . ."
docker build -t tethys-workshop:local "$REPO_ROOT"
echo "Loading the image into the cluster . . ."
k3d image import tethys-workshop:local -c tethys

echo
echo "Deploying the application (kubectl apply -k k8s/base) . . ."
kubectl apply -k "$REPO_ROOT/k8s/base"

echo "Waiting for PostgreSQL to bootstrap (first boot can take a couple of minutes) . . ."
kubectl -n tethys-k8 wait --for=condition=Ready cluster/tethys-postgres --timeout=300s \
  || echo "  (still bootstrapping -- check: kubectl get cluster -n tethys-k8)"

echo "Waiting for the web deployment to roll out . . ."
if kubectl -n tethys-k8 rollout status deploy/tethys-web --timeout=300s; then
  echo
  echo "All set! Open http://localhost:8080   (login: admin / pass)"
else
  echo
  echo "Web not ready yet. If the init Job raced the database on this fresh cluster,"
  echo "just re-run:  kubectl apply -k k8s/base   (the init Job self-cleans and re-runs)."
  echo "Check status: kubectl get pods -n tethys-k8"
fi
