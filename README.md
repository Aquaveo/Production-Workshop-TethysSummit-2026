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

### Static files (already published - nothing to run)

Static assets (CSS/JS) are served from the **jsDelivr CDN**, and `STATIC_URL` is already set
in `k8s/base/portal_config.yml`. As a participant you don't run anything for static - the
portal loads its assets from the CDN automatically.

For reference, `scripts/publish-static.sh` is the **maintainer** tool that produced that URL.
It runs `collectstatic` inside the image, pushes the result to a public `gh-static` branch +
tag, and prints the `https://cdn.jsdelivr.net/gh/<owner>/<repo>@<tag>/` URL that we pasted into
`portal_config.yml`. You'd only touch it if you **fork** the repo and change app static (CSS/JS):
re-run it, bump the `STATIC_URL:` tag in `portal_config.yml`, and `kubectl apply -k k8s/base`.

6. Applying the Manifests

All manifests live under `k8s/base/` and are applied together with Kustomize. The `tethys-config` ConfigMap is generated from `k8s/base/tethys-config.env`, so editing that file and re-applying rolls the change out with no image rebuild.

Apply everything together (the init Job auto-cleans after it finishes via
`ttlSecondsAfterFinished`, so re-applies create a fresh Job — no manual delete needed):

```bash
kubectl apply -k k8s/base
```

`kubectl apply -k` creates everything in order: the namespace, the Traefik Gateway API config, the CNPG PostgreSQL cluster + pooler, Valkey, the PVCs, the Tethys ConfigMap/Secret, the init Job (migrations → superuser → site config), the Tethys web Deployment, nginx, and the Gateway/HTTPRoute.

**How the database wiring works (already baked into the manifests):**

- **Pooler vs. migrations.** Web pods reach PostgreSQL through the pooler - `TETHYS_DB_HOST: tethys-postgres-pooler-rw` in `tethys-config.env`. The init Job overrides `TETHYS_DB_HOST: tethys-postgres-rw` so DDL/migrations run directly against the primary (transaction-mode pooling and schema migrations don't mix). CNPG auto-configures pgbouncer's `auth_query` and the `cnpg_pooler_pgbouncer` role - no manual SQL needed.
- **Users/roles.** The app connects as `tethys_default` using the password from the `tethys-db-app` secret; `tethys_super` is created by CNPG (`managed.roles`) for persistent-store creation. No `tethys db create` step is needed.

> To change config later: edit `k8s/base/tethys-config.env` (or a manifest), then re-run the same two commands above. The web Deployment rolls automatically onto the new hashed ConfigMap (zero-downtime); the init Job is recreated by the delete + apply.

7. Access the portal

The Gateway routes the `localhost` host through the k3d load balancer (`8080:80`), so open:

```
http://localhost:8080
```

Log in with the superuser from the `tethys-secret` (default `admin` / `pass`). Static assets load from the jsDelivr CDN, so the page renders fully styled.

Quick check from the shell:

```bash
curl -I http://localhost:8080/    # expect HTTP 200
```

### Tests: break it, tune it, fix it

A guided exercise: watch the web tier **fail** under load with the minimal default
settings, learn **why**, tune two levers, and watch it **pass**.

> The repo ships intentionally-minimal web resources (`512Mi` limit, `1` uvicorn worker)
> so this demo has something to fix. The tuned values at the end are the sensible baseline.

## The probe
`dev/k8s/ha-probe.sh [URL] [interval]` sends steady traffic and tallies outcomes:
`2xx/3xx` = success, `5xx/000` = real downtime (must stay 0).

---

## Phase 1 - Watch it fail (default: 512Mi, 1 worker)

Point the probe at a **heavy** app page:
```bash
dev/k8s/ha-probe.sh http://localhost:8080/apps/population-app/
```
Within seconds you'll see a storm of `DOWN -> 502` and `FAIL` climbing.

Diagnose in another terminal:
```bash
kubectl get pods -n tethys-k8 -l app=tethys-web        # RESTARTS climbing
kubectl get pods -n tethys-k8 -l app=tethys-web \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}'
#  -> OOMKilled
```

**What's happening:** the population-app page is heavy (~3s, memory-hungry). Rendering it
pushes the pod past its **512Mi** limit, so the kernel **OOM-kills** the container (exit 137).
The pod restarts (a few seconds of downtime) → the proxy returns **502** for requests routed
to it. With a **single uvicorn worker**, the pod also can't overlap requests. The HPA scales
out on CPU, but every new pod OOMs the same way → a continuous 502 storm.

---

## Phase 2 - Tune (two levers, two different problems)

**Lever 1 - Memory (stops the crash).** The page's working set doesn't fit in 512Mi; give it
headroom. In `k8s/base/70-tethys-web.yaml`:
```yaml
resources:
  requests:
    cpu: 250m
    memory: 512Mi
  limits:
    cpu: "1"
    memory: 2Gi     # was 512Mi
```

**Lever 2 - Replicas (concurrency).** Add more *pods*, not in-process workers. Raise the
Deployment's `replicas` (or just let the HPA scale it under load). In `k8s/base/70-tethys-web.yaml`:
```yaml
spec:
  replicas: 4        # was 2  (the HPA still scales 2..8 on CPU)
```
> ⚠ **Don't use uvicorn `--workers >1` with Tethys.** Tethys runs synchronous DB queries at
> import time, so multi-worker uvicorn (which imports the app inside an asyncio event loop)
> crashes with `SynchronousOnlyOperation`. Keep `ASGI_PROCESSES=1` and scale with **replicas**.

Apply (both are in the manifests now):
```bash
kubectl apply -k k8s/base
kubectl rollout status deploy/tethys-web -n tethys-k8
```
(Memory raises what each pod can take before OOM; replicas/HPA add concurrency across pods.)

---

## Phase 3 - Re-run, watch it pass
```bash
dev/k8s/ha-probe.sh http://localhost:8080/apps/population-app/
```
Now: **no OOM, no 502s** - requests return `200`. (Each is still ~3s; the page is genuinely
heavy, but it no longer crashes.) `kubectl get pods` shows **0 new restarts**.

**Optional - prove concurrency scales with replicas.** The sequential probe above sends one
request at a time. Throw concurrent load and watch the HPA add pods:
```bash
hey -z 60s -c 20 http://localhost:8080/apps/population-app/   # 20 concurrent for 60s
kubectl get hpa tethys-web -n tethys-k8 -w                    # replicas scale 2..8 on CPU
```
More replicas spread the concurrent load, so throughput holds instead of collapsing.

---

## What you learned
| Symptom | Lever | Why |
|---|---|---|
| `OOMKilled` / 502 storm | **raise the memory limit** | the page's working set exceeded 512Mi |
| slow / stalls under concurrency | **more replicas** (HPA / `replicas`) | scale out with pods, not in-process workers |
| sustained load spikes | **HPA** (already on) | adds replicas on CPU |
| each render genuinely slow (~3s) | app caching/optimization | that's the app, not the platform |
| `SynchronousOnlyOperation` crash | **keep `ASGI_PROCESSES=1`** | Tethys does sync DB queries at import; uvicorn `--workers >1` can't |

---

## Bonus - zero-downtime during a deploy (use the LIGHT endpoint)

Capacity is one thing; *graceful pod replacement* is another. Probe a **cheap** endpoint so
there's no OOM noise, then churn the pods - `FAIL` should stay **0**:
```bash
dev/k8s/ha-probe.sh http://localhost:8080/accounts/login/    # ~0.02s, won't OOM
# in another terminal:
kubectl rollout restart deploy/tethys-web -n tethys-k8       # FAIL stays 0 (maxUnavailable:0 + readiness)
kubectl delete pod -n tethys-k8 -l app=tethys-web | head -1  # self-heal, FAIL stays 0
```
Contrast: `kubectl scale deploy/tethys-web --replicas=1`, kill the pod → you'll see failures
(no backup); back to `--replicas=2` → zero again. Proves HA comes from the **config**.

## Caveats
- Single host (k3d-on-WSL): pod-level resilience, not node/infra HA.
- The sequential probe shows the **memory/OOM** lesson; **workers** only show up under
  **concurrent** load (the `hey` step).
- DB failover has its own demo below (a brief blip while CNPG promotes a replica - not zero-downtime).

---

## Database HA & pooling

The web tier isn't the only thing that's resilient - Postgres runs **3 CNPG instances**
(1 primary + 2 replicas) behind a **PgBouncer pooler** (2 instances). Two short demos show why.

### Demo 1 - Automatic failover (the value of `instances: 3`)

**Claim:** killing the Postgres *primary* isn't an outage - CNPG promotes a replica on its own.

```bash
# topology: one primary, two replicas
kubectl get pods -n tethys-k8 -l cnpg.io/cluster=tethys-postgres -L cnpg.io/instanceRole

# probe a DB-touching page in another terminal:
dev/k8s/ha-probe.sh http://localhost:8080/apps/

# kill the PRIMARY, then watch a replica take over:
kubectl delete pod -n tethys-k8 -l cnpg.io/cluster=tethys-postgres,cnpg.io/instanceRole=primary
kubectl get pods -n tethys-k8 -l cnpg.io/cluster=tethys-postgres -L cnpg.io/instanceRole -w
```
**What you see:** a **brief** burst of failures (a few seconds while CNPG promotes a replica,
repoints the `tethys-postgres-rw` Service, and the pooler reconnects), then recovery - with
**no manual action**. A different pod is now `primary`.

> ⚠ DB failover is **not** zero-downtime like the web rollout: writes are unavailable for a few
> seconds during promotion. That's expected - the win is *automatic* recovery.

**Contrast:** with `instances: 1` the same kill is a long outage (the single pod must fully
restart, with no replica to promote). 3 instances → seconds.

### Demo 2 - The pooler caps DB connections (scale web, don't exhaust Postgres)

**Claim:** the pooler lets you scale web pods without running Postgres out of connections.

> ⚠ **Connections only pile up under *concurrent* load** - and you must **watch the count *during*
> the load**. The sequential `ha-probe.sh` opens one connection at a time, so it won't show anything
> here; use a concurrent load generator.

```bash
PRIMARY=$(kubectl get pods -n tethys-k8 \
  -l cnpg.io/cluster=tethys-postgres,cnpg.io/instanceRole=primary -o name)
kubectl scale deploy/tethys-web -n tethys-k8 --replicas=8

# Terminal 1 - live DB connection count:
watch -n1 "kubectl exec -n tethys-k8 $PRIMARY -c postgres -- \
  psql -U postgres -d tethys_platform -tAc \
  \"select count(*) from pg_stat_activity where datname='tethys_platform'\""

# Terminal 2 - CONCURRENT load (counts the HTTP status codes):
seq 1 12000 | xargs -P 200 -n1 -I{} curl -s -o /dev/null -w "%{http_code}\n" \
  --max-time 15 http://localhost:8080/apps/ | sort | uniq -c
```

#### With the pooler (the default) - connections stay bounded
Run the load above as-is. **You see:** the count stays **flat (~25-30)** no matter the load or the
8 replicas, and every request is **200**. The pooler multiplexes all those clients onto a small,
fixed set of server connections (~`default_pool_size` × 2 pooler instances). **That flat number is
the whole point.**

#### Bypass the pooler - exhaust Postgres
Two changes make connections accumulate against the DB directly:
```
# k8s/base/tethys-config.env   <-- THIS is the lever.
# (Editing HOST in portal_config.yml does NOT work: the image's ENV TETHYS_DB_HOST="db"
#  is non-empty, so portal-config.sh always stamps the env value over the file.)
TETHYS_DB_HOST=tethys-postgres-rw          # was tethys-postgres-pooler-rw
# k8s/base/portal_config.yml
CONN_MAX_AGE: 60                            # persistent conns pile up (with 0 they're transient)
```
```bash
kubectl apply -k k8s/base
kubectl rollout status deploy/tethys-web -n tethys-k8
```
Re-run the same load. **You see:** the count **climbs to ~97** (Postgres `max_connections` 100,
minus a few reserved for superusers) and the load floods with **500s**:
```bash
kubectl logs -n tethys-k8 -l app=tethys-web --tail=200 | grep "too many clients"
#  FATAL: sorry, too many clients already
```
That's exactly what the pooler prevents - and why a many-replica web tier in front of one Postgres
needs one.

#### Reset when done
```bash
# tethys-config.env: TETHYS_DB_HOST=tethys-postgres-pooler-rw
# portal_config.yml:  CONN_MAX_AGE: 0
kubectl apply -k k8s/base
kubectl scale deploy/tethys-web -n tethys-k8 --replicas=2
```

