#!/usr/bin/env bash
#
# Publish Tethys collected static files to a public GitHub branch so they can be
# served by the jsDelivr CDN (https://cdn.jsdelivr.net/gh/<owner>/<repo>@<tag>/).
#
# Run this LOCALLY (it needs docker + your git push credentials), whenever the
# static assets change (new app, Tethys upgrade, theme change). It:
#   1. extracts the static tree baked into the image (Dockerfile runs collectstatic)
#   2. commits it to an orphan branch (default: gh-static) at the repo root
#   3. creates an immutable tag (jsDelivr caches tags forever -> safe long TTL)
#   4. prints the STATIC_URL to paste into k8s/40-tethys-config.yaml
#
# Usage:
#   scripts/publish-static.sh [IMAGE]
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
trap 'rm -rf "$workdir" "$staticdir"' EXIT

# 1. Generate static on demand inside a throwaway container, then copy it out.
#    (The runtime image no longer bakes collectstatic, so we run it here.)
echo "==> Running collectstatic in image: $IMAGE"
docker run --rm -v "$staticdir:/out" "$IMAGE" bash -c '
  set -euo pipefail
  tethys collectstatic --noinput
  cp -a "${STATIC_ROOT:-/var/lib/tethys_persist/static}/." /out/
'
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
