# Workshop

This is an idea about being able to run tethys using `Uvicorn` instead of `daphne`. The gtethsy container mimics what the original tethys container does with a conda environment, but it uses `uvx`. In addition, it does use nginx on a different container, and it removes the need of supervisord and saltstack on the tethys container.
 
## Plain Docker on VM

## Steps

 ```bash
cp .env.example .env
docker compose build
docker compose up tethys-init
docker compose up -d
```

## Architecture

Docker Compose          k3s / Kubernetes
------------------------------------------------
postgres                StatefulSet + PVC + Service
valkey                  Deployment + Service
tethys-init             Job
tethys-web              Deployment + Service
nginx                   Deployment + Service
docker volumes          PVCs
.env                    ConfigMap + Secret
published port 8080     Traefik Ingress or port-forward

```text
k3s single-node VM or laptop
  ├── Traefik Ingress          # provided by k3s
  ├── nginx Deployment         # your reverse proxy/static server
  ├── tethys-web Deployment    # Uvicorn + Tethys
  ├── tethys-init Job          # migrations, app install, collectall
  ├── postgres StatefulSet     # PostGIS DB
  ├── valkey Deployment        # Redis-compatible service
  └── PVCs                     # TETHYS_HOME, TETHYS_PERSIST, Postgres data
```

## Kubernetes

1. Install Gateway API CRDs

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
```
Check:

```bash
kubectl get crd | grep gateway.networking.k8s.io
```
You should see CRDs like:

```bash
gatewayclasses.gateway.networking.k8s.io
gateways.gateway.networking.k8s.io
httproutes.gateway.networking.k8s.io
```

2. Enable Gateway API support in k3s Traefik


```bash
sudo tee /var/lib/rancher/k3s/server/manifests/traefik-config.yaml >/dev/null <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    providers:
      kubernetesGateway:
        enabled: true
EOF
```

Then watch Traefik reconcile:

```bash
kubectl -n kube-system logs -l app.kubernetes.io/name=traefik --tail=100
```


[GitHub Issue](https://github.com/k3s-io/k3s/discussions/11100)
[Docs](https://docs.k3s.io/networking/networking-services#gateway-api)