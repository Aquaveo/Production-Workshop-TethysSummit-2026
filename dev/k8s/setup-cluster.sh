#!/usr/bin/env bash
set -euo pipefail

echo "Installing k3d . . ."
wget -q -O - https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
echo "k3d installed, creating cluster . . ."

k3d cluster create tethys \
  --servers 1 \
  --agents 1 \
  --k3s-arg "--disable=traefik@server:0" \
  -p "8080:80@loadbalancer" \
  -p "8443:443@loadbalancer" \
  --volume "$HOME/k3d/tethys-storage:/var/lib/rancher/k3s/storage@all"

echo "Cluster created, waiting for nodes to be ready . . ."
kubectl wait --for=condition=Ready nodes --all --timeout=120s
echo "Cluster is ready!"

echo "Installing Gateway API . . ."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
echo "Gateway API installed, waiting for controller to be ready . . ."
kubectl wait --namespace gway-system --for=condition=Ready pod --selector=app=gateway-controller --timeout=120s
echo "Gateway API controller is ready!"

echo "Installing Traefik Ingress Controller . . ."
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm install traefik traefik/traefik \
  --namespace traefik \
  --create-namespace \
  -f traefik-values.yaml

kubectl -n traefik rollout status deployment/traefik
kubectl -n traefik get svc

echo "Traefik installed, waiting for pods to be ready . . ."
kubectl wait --namespace traefik --for=condition=Ready pod --selector=app.kubernetes.io/name=traefik --timeout=120s
echo "Traefik is ready!"

