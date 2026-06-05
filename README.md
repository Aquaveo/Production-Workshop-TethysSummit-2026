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

We have a script at `dev/k8s/setup-cluster.sh` that will do all of the following: 

0. Install k3d

[Docs](https://k3d.io/stable/#install-script)

```bash
wget -q -O - https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
```

```bash
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
```

1. Create a cluster

```bash
k3d cluster create tethys \
  --servers 1 \
  --agents 1 \
  --k3s-arg "--disable=traefik@server:0" \
  -p "8080:80@loadbalancer" \
  -p "8443:443@loadbalancer" \
  --volume "$HOME/k3d/tethys-storage:/var/lib/rancher/k3s/storage@all"
```
The -p "8080:80@loadbalancer" mapping exposes traffic from your host's localhost:8080 to port 80 through the k3d load balancer. [k3d documents](https://k3d.io/v5.3.0/usage/exposing_services/) this pattern for exposing HTTP traffic through the cluster load balancer.

2. Install Gateway API CRDs

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

3. Install Traefik with Gateway API enabled

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update
```
Create traefik-values.yaml:

```yaml
providers:
  kubernetesCRD:
    enabled: true
  kubernetesIngress:
    enabled: false
  kubernetesGateway:
    enabled: true

gateway:
  enabled: false

service:
  type: LoadBalancer

ports:
  web:
    port: 8000
    exposedPort: 80
    expose:
      default: true
  websecure:
    port: 8443
    exposedPort: 443
    expose:
      default: true
```

Install:

```bash
helm install traefik traefik/traefik \
  --namespace traefik \
  --create-namespace \
  -f traefik-values.yaml
```

Wait

```bash
kubectl -n traefik rollout status deployment/traefik
kubectl -n traefik get svc
```

