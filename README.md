# Workshop

This is an idea about being able to run tethys using `Uvicorn` instead of `daphne`. The tethys container mimics what the original tethys container does with a conda environment, but it uses `uv`. In addition, it runs nginx in a separate container, and it removes the need for supervisord and saltstack in the tethys container.
 
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
postgres                CNPG Cluster (3 instances) + Services
(connection pool)       CNPG Pooler (PgBouncer)
valkey                  Deployment + PVC + Service
tethys-init             Job
tethys-web              Deployment (replicas + HPA) + Service
nginx                   Deployment + Service
docker volumes          PVCs
.env                    ConfigMap + Secret (generated via Kustomize)
static files            jsDelivr CDN (STATIC_URL)
published port 8080     Traefik + Gateway API (HTTPRoute)

```text
k3s single-node laptop (k3d)
  ├── Traefik (Gateway API)    # Helm-installed; bundled k3s Traefik disabled
  ├── nginx Deployment         # reverse proxy + /media, /workspaces
  ├── tethys-web Deployment    # Uvicorn + Tethys
  ├── tethys-init Job          # migrations, superuser, site config
  ├── CNPG PostgreSQL          # PostGIS, 3 instances + PgBouncer pooler
  ├── valkey Deployment        # Redis-compatible (Django Channels)
  └── PVCs                     # TETHYS_PERSIST + Postgres data
                               # (TETHYS_HOME is an emptyDir; static served from the CDN)
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


5. Build the image and save it on `k3d`

```bash
docker build -t tethys-workshop:local .
k3d image import tethys-workshop:local -c tethys
```

Up to this point the script at `dev/k8s/setup-cluster.sh` will do most of the heavy lifting, but we need to do the rest now. Which is to play with the `yaml` files

6. Collect the static files

```bash
  scripts/publish-static.sh                          # publishes -> prints STATIC_URL with a tag
```

paste that STATIC_URL into `k8s/base/portal_config.yml` (the `STATIC_URL:` line under `settings:`). Kustomize generates the `tethys-portal-config` ConfigMap from this file.

**Note** Everytime you update the static files: re-run publish-static.sh only when static assets change, and bump the tag on the `STATIC_URL:` line in `k8s/base/portal_config.yml`.

7. Applying the Manifests

All manifests live under `k8s/base/` and are applied together with Kustomize. The `tethys-config` ConfigMap is generated from `k8s/base/tethys-config.env`, so editing that file and re-applying rolls the change out with no image rebuild.

The init Job's pod template is immutable, so delete any previous run before (re)applying:

```bash
kubectl delete job tethys-init -n tethys-k8 --ignore-not-found
kubectl apply -k k8s/base
```

`kubectl apply -k` creates everything in order: the namespace, the Traefik Gateway API config, the CNPG PostgreSQL cluster + pooler, Valkey, the PVCs, the Tethys ConfigMap/Secret, the init Job (migrations → superuser → site config), the Tethys web Deployment, nginx, and the Gateway/HTTPRoute.

**How the database wiring works (already baked into the manifests):**

- **Pooler vs. migrations.** Web pods reach PostgreSQL through the pooler - `TETHYS_DB_HOST: tethys-postgres-pooler-rw` in `tethys-config.env`. The init Job overrides `TETHYS_DB_HOST: tethys-postgres-rw` so DDL/migrations run directly against the primary (transaction-mode pooling and schema migrations don't mix). CNPG auto-configures pgbouncer's `auth_query` and the `cnpg_pooler_pgbouncer` role - no manual SQL needed.
- **Users/roles.** The app connects as `tethys_default` using the password from the `tethys-db-app` secret; `tethys_super` is created by CNPG (`managed.roles`) for persistent-store creation. No `tethys db create` step is needed.

> To change config later: edit `k8s/base/tethys-config.env` (or a manifest), then re-run the same two commands above. The web Deployment rolls automatically onto the new hashed ConfigMap (zero-downtime); the init Job is recreated by the delete + apply.

8. Access the portal

The Gateway routes the `localhost` host through the k3d load balancer (`8080:80`), so open:

```
http://localhost:8080
```

Log in with the superuser from the `tethys-secret` (default `admin` / `pass`). Static assets load from the jsDelivr CDN, so the page renders fully styled.

Quick check from the shell:

```bash
curl -I http://localhost:8080/    # expect HTTP 200
```