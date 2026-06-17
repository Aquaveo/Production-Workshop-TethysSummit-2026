# Workshop Concepts - Questions, Misconceptions, and Why They Improve Tethys Deployments

This document distills the **conceptual** questions raised while modernizing the Tethys
deployment (Docker-Compose + k3d/Kubernetes). Each entry follows the same shape:

> **The question** → **The misconception (if any)** → **The concept** → **What it changes / optimizes**

It is meant to be read aloud as workshop material: the "before" is how Tethys is commonly
deployed today; the "after" is where this work lands.

---

## 1. Why not put passwords in the Dockerfile?

**Question:** "How do we see the `SecretsUsedInArgOrEnv` lint warnings?"

**Misconception:** *"`ENV DB_PASSWORD=...` in the Dockerfile is fine - it's just a default."*

**Concept - image layers are public.** Every `ENV` / `ARG` is baked into an image layer
and is readable forever via `docker history` / `docker inspect`, even if a later layer
"overwrites" it. An image is a distributable artifact; treat anything in it as published.

```
BAKED INTO IMAGE (readable via docker history)   INJECTED AT RUNTIME (never in a layer)
  TETHYS_DB_NAME       non-secret  ✅               TETHYS_DB_PASSWORD   ← .env / k8s Secret
  TETHYS_DB_USERNAME   non-secret  ✅               TETHYS_SECRET_KEY    ← .env / k8s Secret
  TETHYS_DB_HOST       non-secret  ✅               PORTAL_SUPERUSER_PASSWORD
                                                    scripts default: "${TETHYS_DB_PASSWORD:-pass}"
```

**What it changes for Tethys:** the same image is safe to push to a shared/public registry.
Secrets live in `.env` (Compose) or `Secret` objects (k8s) - rotated without rebuilding the
image. One image, many environments.

---

## 2. What does it actually take to run as non-root?

**Question:** "What do we need to avoid running the container as root?"

**Misconception:** *"Add `USER 1000` at the end and `chown -R` the directories."*

**Concept - ownership by construction beats chown.** A non-root user can only write where it
owns the path. The cheap way to guarantee that is to **switch user first, then create the
directories** - they're born owned by that user. No recursive `chown` (which is slow and
bloats a layer) anywhere.

```
USER 1000:1000                       ← switch FIRST
RUN mkdir -p /home/tethys/{portal,log,persist,apps,...}   ← created AS 1000 → owned by 1000
```

**What it changes for Tethys:** the container drops root entirely. On k8s this is enforced by a
`securityContext` (`runAsNonRoot`, `runAsUser/Group: 1000`, `seccompProfile: RuntimeDefault`),
which satisfies Pod Security Standards "restricted" - the bar most clusters now require.

---

## 3. Why `useradd --create-home`, specifically?

**Question:** "Why do we need `RUN useradd --uid 1000 --create-home --home-dir /home/tethys ...`?"

**Misconception:** *"A uid is just a number - `USER 1000` is enough, I don't need a real user."*

**Concept - software expects a passwd entry.** Two distinct things come from `useradd`:
1. **`--create-home`** → `/home/tethys` is owned by uid 1000. That ownership is what makes the
   "create dirs after USER" trick work.
2. **The passwd entry itself** → `getpwuid(1000)` resolves, so `os.path.expanduser("~")`,
   the Python venv, and Django's startup find a real home. A bare numeric uid breaks these.

**What it changes for Tethys:** Tethys/Django start cleanly as a non-root, *named* user - no
"`KeyError: getpwuid(): uid not found`" surprises, no `HOME` hacks.

---

## 4. Put state under `$HOME`, not system dirs

**Question:** "What about using standard paths that don't require root for `TETHYS_HOME`, etc.?"

**Misconception:** *"Tethys must live in `/usr/lib/...` and `/var/lib/...` like a system service."*

**Concept - relocate writable state under the user's home.** System dirs are root-owned; writing
there forces either root or chown. Putting *all mutable Tethys state* under `/home/tethys`
(owned by 1000) removes the conflict entirely.

```
BEFORE (root-owned, needs chown)      AFTER (owned by uid 1000, zero chown)
  /usr/lib/tethys              →        /home/tethys/portal    (TETHYS_HOME)
  /var/log/tethys              →        /home/tethys/log       (TETHYS_LOG)
  /var/lib/tethys/persist      →        /home/tethys/persist   (TETHYS_PERSIST)
                                        /home/tethys/apps      (TETHYS_APPS_ROOT)
```

**What it changes for Tethys:** one ownership boundary (`/home/tethys`) instead of scattered
root-owned dirs. Applied identically to Compose **and** k8s, so both run on the *same* non-root
image - the deployments stay in lockstep.

---

## 5. Unprivileged nginx can't bind low ports

**Question:** "Why do we need the unprivileged-nginx?"

**Misconception:** *"nginx always listens on 80."*

**Concept - ports below 1024 require a capability (`CAP_NET_BIND_SERVICE`) a non-root process
doesn't have.** The unprivileged nginx image (uid 101) therefore listens on **8080**; the
platform maps the public port to it.

```
nginx listens 8080  (not 80)        Compose: 8080:8080
                                    k8s Service: port 80 → targetPort 8080
```

**What it changes for Tethys:** the *entire* request path is non-root - app tier (uid 1000) and
proxy tier (uid 101). Nothing in the stack needs root.

---

## 6. Provisioning belongs to the database, not the app

**Question:** "Does the db/user creation needs to be created via`tethys db createsuperuser`."

**Misconception:** *"Tethys needs a superuser connection so it can create its own roles and
database at startup."*

**Concept - separate one-time provisioning from steady-state runtime.** The database creating
*itself* (roles, DB) is a privileged, one-time act. The app *using* it is a recurring,
low-privilege act. Conflating them means the app holds superuser forever. Postgres has a
first-boot hook built for exactly the provisioning half:

```
/docker-entrypoint-initdb.d/10-create-tethys-db.sh   (runs ONCE, as the postgres superuser)
   CREATE ROLE tethys_default LOGIN PASSWORD ...                 (owns the DB)
   CREATE ROLE tethys_super   LOGIN SUPERUSER CREATEDB ...
   CREATE ROLE tethys_app     LOGIN CREATEDB ...                 (least-privilege, see §9)
   CREATE DATABASE tethys_platform OWNER tethys_default
```

This mirrors CloudNativePG's `bootstrap.initdb` on the k8s side - same idea, two platforms.

**What it changes for Tethys:** the app no longer needs superuser to bootstrap. Provisioning is
auditable, declarative, and runs exactly once. The runtime role is least-privilege.

---

## 7. Config scripts are convergence, not installation

**Question:** "How many times do we need to run `portal-config.sh` / `portal-bootstrap.sh` multiple, once?"

**Misconception:** *"These are install steps - gate them with an `init_complete` flag so they
never run again."*

**Concept - idempotent reconcile loop vs one-shot installer.** These scripts re-apply
*desired state* (settings, branding, superuser) from a declarative source every deploy. Running
them again is cheap and **corrects drift** - if someone edits `portal_config.yml`, the next
deploy reflects it. A one-shot guard would freeze the first-ever config forever.

```
One-shot installer (rejected)        Convergence script (chosen)
  if init_complete: skip               run every deploy (idempotent)
  → config edits never propagate       → edits to portal_config.yml take effect next `up`
```

**What it changes for Tethys:** configuration becomes **declarative and GitOps-friendly**.
Edit the mounted `portal_config.yml`, redeploy, done - no manual `tethys settings --set`,
no rebuild (mounted files don't need one).

> **Operational corollary (a real gotcha we hit):** mounted files (`portal_config.yml`) apply on
> `up`, but `scripts/*.sh` are **COPY'd into the image** - editing one requires
> `docker compose build` before `up`. Mount = no rebuild; baked = rebuild.

---

## 8. A pooler multiplexes connections; transaction mode is the catch

**Question:** "Can we add a pooler to the Docker Compose? How does it show a benefit?"

**Misconception:** *"More web workers = more Postgres connections; that's just how it scales."*

**Concept - Postgres connections are expensive and finite; pool in front of them.** PgBouncer in
**transaction mode** binds a server connection to a client only for the duration of one
transaction, so hundreds of clients share a handful of server connections.

```
        many web requests
              │
              ▼
      ┌──────────────┐   transaction-mode   ┌──────────┐
 web →│   pgbouncer  │ ───────────────────► │ postgres │
      │ 1000 clients │  60 clients ≈ 3 conns│          │
      │  pool_size 25│                       └──────────┘
      └──────────────┘
 init / migrations BYPASS the pooler → connect DIRECT (DDL needs a real session)
```

**The catch - transaction mode breaks *session-scoped* state**, not writes:
`✗ server-side prepared statements ✗ session SET/GUCs ✗ advisory locks ✗ LISTEN/NOTIFY
✗ WITH HOLD cursors ✗ temp tables`. Django must set `DISABLE_SERVER_SIDE_CURSORS: true` and
`CONN_MAX_AGE: 0` to be safe.

**What it changes for Tethys:** Tethys can scale web workers without exhausting Postgres
connections. Proven: 60 concurrent clients collapsed to ~3 server connections.

---

## 9. The privilege ladder (and what a persistent store actually needs)

**Question:** "Do the persistent-store steps (create service → link → syncstores) require superuser?"

**Misconception:** *"Creating databases, tables, and extensions all needs superuser."*

**Concept - privileges are a ladder, and most rungs are below superuser:**

```
CREATE TABLE        ← needs schema CREATE, granted by OWNING the schema   (NOT superuser)
CREATE DATABASE     ← needs the CREATEDB role attribute                   (NOT superuser)
CREATE EXTENSION postgis / CREATE ROLE SUPERUSER  ← genuinely SUPERUSER-only
```

So a **non-super role with CREATEDB** can provision a *non-spatial* persistent store completely.
`dam_inventory`'s `primary_db` is non-spatial → no superuser needed.

**What it changes for Tethys:** persistent-store provisioning drops from "superuser" to a
narrowly-scoped `tethys_app` role (`LOGIN CREATEDB`, non-super) - least privilege end to end.

---

## 10. The big one: writes do NOT break through the pooler

**Question:** "After `syncstores`, the app runs as superuser. If I flip the host to the pooler,
won't writes break? Do I need two stores - one for reads via the pooler, one for writes via Postgres?"

**Misconception (two layered ones):**
1. *"Writes break through a transaction-mode pooler."*
2. *"Therefore I need a split read-store / write-store topology."*

**Concept - transaction pooling is per-transaction; a write IS a transaction.** What breaks is
*session-scoped state that must survive across transactions* (prepared statements, advisory
locks, temp tables...). INSERT/UPDATE/DELETE/CREATE TABLE are self-contained transactions and pass
through fine. **Empirically disproven the misconception:** 500 inserts + 250 updates + deletes,
as a *non-super* role, through *transaction-mode* PgBouncer → exit 0.

```
The real problem was never WRITES - it was ROLE COUPLING:
  Tethys uses ONE persistent-store service for BOTH syncstores (DDL) AND runtime queries,
  so the app runs as whatever role provisioned it.

  Wrong fix:  two stores (read via pooler / write via postgres)   ← solves a non-problem
  Right fix:  provision as a least-privilege role (tethys_app)    ← fixes the actual coupling
```

**What it changes for Tethys:** a single store, behind the pooler, owned by a least-privilege
role. No split topology, no superuser at runtime. This is the conceptual heart of the workshop -
the database wiring people *think* they need is more complex than what they *actually* need.

---

## 11. Non-super users can create tables (because they own the schema)

**Question:** "Can non-super users create tables?"

**Misconception:** *"`CREATE TABLE` is a privileged operation, so the role must be elevated."*

**Concept - `CREATE TABLE` requires `CREATE` on the *schema*, which ownership grants.** Since
`tethys_default` owns `tethys_platform`, it owns the `public` schema, so it can create tables -
no superuser involved. (Note PG15+: `PUBLIC` lost `CREATE` on `public`; only the DB owner has it
by default - which is exactly the role Tethys uses.)

**What it changes for Tethys:** confidence that the least-privilege model is sufficient. The app
role owns its data and can fully manage it without elevation.

---

## 12. A least-privilege role needs its own "maintenance" database

**Question:** "Isn't it enough to run `tethys link` and then `tethys syncstores`? Why does the
least-privilege `tethys_app` role also need a database *named* `tethys_app`?"

**Misconception:** *"`link` + `syncstores` is the whole story - if the role can create databases,
syncstores will just create the store."*

**Concept - `syncstores`' `CREATE DATABASE` needs an existing database to connect to first, and
it defaults that to the role name.** `link` and the store creation happen at two different layers:

```
tethys link       writes a service<->setting association ROW into the PORTAL db   (metadata only)
tethys syncstores CONNECTS to the target Postgres and runs CREATE DATABASE        (needs a landing db)
```

`link` never touches the target server. `syncstores` is the first step that actually connects -
and the persistent-store service URL carries **no database name** (`database = None` in
`tethys_services/models.py`), so libpq defaults the dbname to the **connecting username**. The
stock `postgres` superuser works only because a `postgres` database happens to exist; a
least-privilege `tethys_app` role has no same-named database, so the connection fails before any
`CREATE DATABASE` can run:

```
role tethys_app present, but NO `tethys_app` database:
  tethys link        -> OK   (just a metadata row)
  tethys syncstores  -> FATAL: database "tethys_app" does not exist
```

The maintenance database is therefore **orthogonal** to the CLI ordering - it's a one-time,
DB-layer prerequisite that belongs with role creation (Compose initdb / CNPG `Database` CRD), not
in the link/syncstores sequence. The only alternative is to point the store at a role that already
owns a same-named db (e.g. the `postgres` superuser) - which is exactly the superuser-at-runtime
coupling Option B exists to avoid (see §10).

**What it changes for Tethys:** Option B (least-privilege persistent stores) is only complete when
the deployment also provisions a `tethys_app` maintenance database. With it, `syncstores` creates
and owns the store as a non-superuser; without it, the "least-privilege store" silently can't be
created at all.

> **Bonus gotcha:** `tethys syncstores` (like `tethys manage`) **swallows its subcommand exit
> code** - it prints a traceback yet still returns `0`. An automated provisioning step must
> *verify the store database exists afterward* and fail explicitly, or a broken provision reports
> success. (Same exit-code-swallow class as the migration gate in the k8s notes.)

---

## 13. Config in a ConfigMap "just rolls out" - because the name is hashed

**Question:** "`portal_config.yml` is a ConfigMap - how does editing it take effect without a
rebuild or a manual restart? Does Tethys hot-reload it?"

**Misconception:** *"The pod re-reads the mounted ConfigMap live, so editing it updates the running
portal."* (Or the opposite: *"I have to rebuild the image / manually restart pods to change config."*)

**Concept - the kustomize content-hash suffix turns a config edit into a rolling restart.**
Two distinct wins that are easy to conflate:

1. **No image rebuild** - `portal_config.yml` is *data in a ConfigMap*, not baked into an image
   layer. (Contrast `scripts/*.sh`, which are `COPY`'d into the image -> editing those *does* need
   a rebuild. Mounted vs. baked.)
2. **No manual restart** - `configMapGenerator` names the ConfigMap by a content hash, so:

```
edit portal_config.yml
  → ConfigMap name changes:  tethys-portal-config-<hashA> → -<hashB>
  → the Deployment's volume ref changes  → the POD TEMPLATE changes
  → Kubernetes does an automatic RollingUpdate (maxUnavailable: 0 = zero downtime)
```

The crucial nuance: this is a **restart, not in-place hot-reload**. Tethys reads
`portal_config.yml` once at startup (Django settings import); nothing watches the file. Each new
pod re-runs the `configure` initContainer (copies the ConfigMap into the `home` emptyDir + injects
secrets), then uvicorn starts and reads the new values. "No reload" = you never rebuild the image
and never restart pods by hand - the hash-driven rollout *is* the restart, done for you.

Why the hash matters: a **plain** (un-hashed) ConfigMap edit would silently *not* take effect -
the kubelet eventually syncs the new file into the pod (~1 min), but the running uvicorn never
re-reads it, and nothing changes the pod template so **nothing restarts**. The hash fixes both.

**What it changes for Tethys:** config becomes a one-command, zero-downtime, GitOps-friendly
edit (`edit portal_config.yml` → `kubectl apply -k`) - no rebuild, no `tethys settings --set`, no
manual rollout. (Caveat: hashed names accumulate stale `tethys-portal-config-<oldhash>` ConfigMaps
unless you `apply --prune`; they're harmless.) See also §7 (convergence, not installation).

---

## 14. ...but a *literal* ConfigMap does NOT auto-roll (the nginx config)

**Question:** "Does the nginx config behave like the portal config in §13 - edit it and it rolls
out automatically?"

**Misconception:** *"All ConfigMaps auto-roll on `kubectl apply -k`."* The hash-driven rollout
from §13 is a property of `configMapGenerator`, **not** of ConfigMaps in general.

**Concept - only *generated* ConfigMaps get the content-hash suffix.** The nginx config is split
into two parts that behave differently:

```
nginx envsubst VARIABLES (CLIENT_MAX_BODY_SIZE, TETHYS_PORT)
    sourced via configMapKeyRef from the HASHED tethys-config  → edit -> auto-rolls   ✅ (like §13)

nginx config TEMPLATE itself (the proxy rules, location blocks)
    a LITERAL `kind: ConfigMap` named nginx-config, listed under resources:, NOT generated
    → no hash suffix → name never changes → pod template never changes → NO auto-rollout  ❌
```

Worse, even after the kubelet eventually syncs the edited file into the pod (~1 min), nginx won't
apply it: the nginxinc image runs **envsubst at container startup** (`/etc/nginx/templates/*.template`
-> `/etc/nginx/conf.d/default.conf`) and never re-renders or `nginx -s reload`s on a file change.
So editing the template needs a manual rollout:

```bash
kubectl -n tethys-k8 rollout restart deploy/nginx
```

To make it behave like §13, move the template into a `configMapGenerator` (`files:` entry) and
delete the literal ConfigMap - then a template edit changes the hash and nginx auto-rolls.

**What it changes for Tethys:** a precise mental model of *which* config edits are
one-command-zero-downtime (anything generated: `tethys-config`, `tethys-portal-config`) versus
which need a manual `rollout restart` (the literal `nginx-config`). When in doubt: *generated =
auto-rolls, literal = manual*. (Compose parallel: bind-mounted `tethys_nginx.conf` likewise needs
`docker compose restart nginx`.) See §13 for the generated-ConfigMap case.

---

## 15. Source of truth: the database vs. portal_config.yml

**Question:** "Some settings are in `portal_config.yml`, some are in the database, and the admin UI
edits settings too. Which one is the source of truth?"

**Misconception:** *"The DB and the file are two copies of the same settings, so one must override
the other."* They don't overlap that way - they own **different** settings, with different rules.

**Concept - three buckets, two sources of truth.**

```
                  portal_config.yml (file)              Postgres (DB)
1. Django/infra   ████ SOLE source of truth ███ ─read once at startup─▶ (no copy in DB)
   DATABASES, ALLOWED_HOSTS, SECRET_KEY, STATIC_URL, DEBUG, LOGGING,
   INSTALLED_APPS, CHANNEL_LAYERS, TETHYS_PORTAL_CONFIG

2. site_settings: declarative seed ──tethys site -f (EVERY init)──▶ ████ live store ████
   (branding/content)   non-empty key  → OVERWRITES the DB   → FILE wins (re-applied each deploy)
                        empty/blank key → skipped            → DB wins (admin-UI edit persists)

3. app settings /  (not in the file at all)                      ████ DB only ████
   persistent stores                                             set via CLI / admin UI
```

1. **Django / infrastructure settings** - the file is the *only* source of truth; the DB stores no
   copy, so nothing can be "out of sync." `tethys settings --set` (how `portal-config.sh` injects
   `SECRET_KEY` / DB password / host) **mutates the file**, not the DB. Read once at Django startup
   -> change = edit file + pod restart (§13).
2. **Site / branding content** - the **DB** is the runtime store (what the portal serves and what
   the admin UI edits). `portal_config.yml`'s `site_settings:` block is a one-way **seed**:
   `portal-bootstrap.sh` runs `tethys site -f` on *every* init (convergence, §7), so per key,
   `tethys_cli/site_commands.py` does `if content and obj: obj.update(...)` - **non-empty file
   values overwrite the DB; empty values are skipped.**
3. **App settings & persistent stores** - DB only; the file never mentions them.

**The practical gotcha:** branding tweaks made in the **admin UI** stick **only** for keys you left
**blank** in the file. Any key with a non-empty `site_settings:` value is reset to the file's value
on the next `kubectl apply -k`. Rule of thumb: **manage via UI -> leave it blank in the file;
pin it / make it reproducible -> set it in the file.**

**What it changes for Tethys:** no guessing about "did my change take?" - infra settings are
file-authoritative (restart to apply), branding is DB-authoritative *except* for the keys the file
declares (which it re-asserts every deploy). Same convergence philosophy as §7: the file is
desired-state for what it declares, and silent about the rest.

---

## 16. Env vars vs. portal_config.yml (e.g. the DB host)

**Question:** "The DB host is both an env var (`TETHYS_DB_HOST`) and a setting in
`portal_config.yml` (`DATABASES.default.HOST`). Which one does Tethys use?"

**Misconception:** *"Django reads `TETHYS_DB_HOST` from the environment."* It doesn't - it only
reads `portal_config.yml` (`settings.py:120` pops `DATABASES` from the file; the sole env var it
reads directly is `DJANGO_LOG_LEVEL`).

**Concept - env vars are *ingredients*; the file is what Django reads.** At startup,
`portal-config.sh` takes the env var and **writes it into** the file:

```
TETHYS_DB_HOST (env)  ──portal-config.sh writes it──▶  portal_config.yml HOST  ──▶  Django reads this
```

So there's still **one** runtime source of truth: the file. The env var just decides what gets
written into it before Django boots. (For that one key, env therefore "wins" over the file's
literal value - only because the inject step runs after the file is copied.)

Why have the env var at all? So the *same* committed file can point at a different host per pod:

```
init Job → env says ...-rw         → file gets the DIRECT db  → migrations skip the pooler
web pod  → env says ...-pooler-rw  → file gets the POOLER     → web tier is pooled
```

Only **three** settings work this way (env → injected into the file): `SECRET_KEY`, DB `PASSWORD`,
DB `HOST` - because they're either secret or change per environment/pod. Every other setting
(`ALLOWED_HOSTS`, `STATIC_URL`, ...) is just written literally in the file.

**What it changes for Tethys:** one-liner to remember - *env vars are inputs baked into the config
file at startup; the file is the only thing Django actually reads.* (Contrast §15, which is about
file vs. DB; this is about env vs. file.)

---

## One-slide summary: before → after

| Dimension            | Common Tethys deploy (before)        | This workshop (after)                          |
|----------------------|--------------------------------------|------------------------------------------------|
| Secrets              | baked into image `ENV`               | injected at runtime (`.env` / k8s Secret)      |
| User                 | root                                 | non-root uid 1000 (+ nginx uid 101)            |
| State location       | scattered root-owned system dirs     | one home-owned tree `/home/tethys/*`           |
| DB/role creation     | Tethys w/ superuser at startup       | Postgres first-boot hook / CNPG `initdb`       |
| App DB role          | superuser at runtime                 | least-privilege `tethys_app` (CREATEDB)        |
| Config               | imperative `tethys settings --set`   | declarative mounted `portal_config.yml`        |
| Connections          | 1 per worker → exhaustion            | PgBouncer transaction pooling                  |
| Static assets        | served from a volume by nginx        | jsDelivr CDN (immutable tag)                   |
| Compose vs k8s       | divergent setups                     | same image + same scripts, in lockstep         |
