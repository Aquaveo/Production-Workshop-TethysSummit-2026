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
4. Install CNPG -  Cloud Native PostgreSQL

```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.29/releases/cnpg-1.29.1.yaml
```

```bash
kubectl rollout status deployment \
  -n cnpg-system cnpg-controller-manager
```


6. Built the image and save it on `k3d`

```bash
docker build -t tethys-workshop:local .
k3d image import tethys-workshop:local -c tethys
```

Up to this point the script at `dev/k8s/setup-cluster.sh` will do most of the heavy lifting, but we need to do the rest now. Which is to play with the `yaml` files

7. Collect the static files

```bash
  scripts/publish-static.sh                          # publishes -> prints STATIC_URL with a tag
```

paste that STATIC_URL into k8s/40-tethys-config.yaml (replace the placeholder tag)

**Note** Everytime you update the static files: Re-run publish-static.sh only when static assets change, and bump the tag in the ConfigMap.

8. Applying the Manifests

a. Create the namespace

```bash
kubectl apply -f k8s/00-namespace.yaml
```
b. create the CNPG PostgreSQL Cluster

```bash
kubectl apply -f k8s/10-cnpg-postgres.yaml
```

c. Let's add a pooler

```bash
 kubectl apply -f k8s/15-cnpg-pooler.yaml
```
This creates a Service named tethys-postgres-pooler-rw in the namespace. CNPG also auto-configures pgbouncer's auth_query and the cnpg_pooler_pgbouncer role for you (because the operator manages this cluster) - no manual SQL needed.

Point the app at the pooler - but keep migrations direct.

This is the key nuance. Send runtime web traffic through the pooler, but run DDL/migrations directly against the primary, because transaction-mode pooling and schema migrations don't mix well.

In k8s/40-tethys-config.yaml, the web pods use the pooler:

`TETHYS_DB_HOST: "tethys-postgres-pooler-rw"`   # was tethys-postgres-rw
But the bootstrap Job (migrate/createsuperuser) should override back to the direct service:

in 60-tethys-init-job.yaml, on the bootstrap container:

```yaml
env:
  - name: TETHYS_DB_HOST
    value: "tethys-postgres-rw"     # DDL on a real session, bypass pgbouncer
```

d. Deploy Valkey

```bash
kubectl apply -f k8s/20-valkey.yaml
```
e. Create the pvcs for Tethys

```bash
kubectl apply -f k8s/30-tethys-pvcs.yaml
```
f. Create the config map for Tethys

```bash
kubectl apply -f k8s/40-tethys-config.yaml
```

g. Create the secrets for Tethys

```bash
kubectl apply -f k8s/50-tethys-secret.yaml
```

Keep `TETHYS_DB_USERNAME: tethys_default`, `TETHYS_DB_HOST: tethys-postgres-rw`, etc. The app connects as `tethys_default` with the password from the `tethys-db-app` secret (already wired). `TETHYS_DB_SUPERUSER: tethys_super` can stay - Tethys uses it later for persistent-store creation, and that role now exists via CNPG

h. Create the init jobs for Tethys

```bash
kubectl apply -f k8s/60-tethys-init-job-yaml
```

i. Create the actual tethys deployment.

```bash
kubectl apply -f k8s/70-tethys-web.yaml
```
j. Create the actual nginx configuration

```bash
kubectl apply -f k8s/80-nginx.yaml
```
k. Create the gateway and httroutes resources.

```bash
kubectl apply -f k8s/90-gateway-api.yaml
```