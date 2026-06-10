#!/usr/bin/env bash
#
# Publish Tethys collected static files to a public GitHub branch so they can be
# served by the jsDelivr CDN (https://cdn.jsdelivr.net/gh/<owner>/<repo>@<tag>/).
#
# Run this LOCALLY (it needs docker + your git push credentials), whenever the
# static assets change (new app, Tethys upgrade, theme change). It:
#   1. runs collectstatic inside a throwaway container from the image
#   2. commits it to an orphan branch (default: gh-static) at the repo root
#   3. creates an immutable tag (jsDelivr caches tags forever -> safe long TTL)
#   4. prints the STATIC_URL to paste into k8s/40-tethys-config.yaml
#
# Usage:
#   dev/publish-static.sh [IMAGE]
# Env overrides:
#   STATIC_REPO_URL  git remote to push to   (default: this repo's origin)
#   STATIC_BRANCH    branch to hold static   (default: gh-static)
#   STATIC_TAG       tag to create           (default: static-<UTC timestamp>)
set -euo pipefail

IMAGE="${1:-tethys-workshop:local}"
REPO_URL="${STATIC_REPO_URL:-$(git config --get remote.origin.url)}"
BRANCH="${STATIC_BRANCH:-gh-static}"
TAG="${STATIC_TAG:-static-$(date -u +%Y.%m.%d-%H%M%S)}"

# owner/repo for the printed jsDelivr URL, parsed from the remote
slug="$(printf '%s' "$REPO_URL" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"

workdir="$(mktemp -d)"
staticdir="$(mktemp -d)"
cid=""
trap '[ -n "$cid" ] && docker rm -f "$cid" >/dev/null 2>&1; rm -rf "$workdir" "$staticdir"' EXIT

# 1. Generate static inside a throwaway container, then copy it out.
#    - `tethys settings --set STATIC_ROOT /tmp/collected` pins a known output dir: the
#      image's portal_config has no STATIC_ROOT, so Django would otherwise default
#      it to /home/tethys/persist/static.
#    - `tethys db migrate` first: migrate is the ONLY command exempt from Tethys's
#      cookie-sync in apps.ready() (tethys_apps/apps.py), so it can create tables
#      in the container's local sqlite; collectstatic then runs without the
#      "no such table: cookie_consent_cookiegroup" crash.
#    - docker cp (not a bind mount) so the extracted files are owned by the host
#      user, not root (otherwise cleanup fails with "Operation not permitted").
echo "==> Collecting static in image: $IMAGE"
cid="$(docker create "$IMAGE" bash -c '
  set -euo pipefail
  mkdir -p /tmp/collected
  tethys settings --set STATIC_ROOT /tmp/collected >/dev/null
  tethys db migrate >/dev/null
  tethys manage collectstatic --noinput
')"
docker start -a "$cid"
docker cp "$cid:/tmp/collected/." "$staticdir/"
docker rm -f "$cid" >/dev/null; cid=""
[ -n "$(ls -A "$staticdir")" ] || { echo "ERROR: collectstatic produced no files" >&2; exit 1; }

# 2. Put them on a clean orphan branch at the repo root
echo "==> Publishing to $slug branch '$BRANCH'"
git clone --quiet "$REPO_URL" "$workdir"
cd "$workdir"
git checkout --orphan "$BRANCH"
git rm -rfq . >/dev/null 2>&1 || true
cp -a "$staticdir/." .
printf '%s\n' "Auto-generated Tethys static assets served via jsDelivr. Do not edit by hand." > README.md
git add -A
git -c user.name="${GIT_AUTHOR_NAME:-static-publisher}" \
    -c user.email="${GIT_AUTHOR_EMAIL:-static-publisher@users.noreply.github.com}" \
    commit -qm "Publish static $TAG"

# 3. Immutable tag + push
git tag "$TAG"
git push --quiet --force origin "$BRANCH"
git push --quiet origin "$TAG"

# 4. Tell the operator what to wire in
cat <<EOF

==> Done. Set this in k8s/40-tethys-config.yaml (then re-apply + restart tethys-web):

  STATIC_URL: "https://cdn.jsdelivr.net/gh/${slug}@${TAG}/"

EOF
