#!/usr/bin/env bash
# ngris deploy-action — build → zip → upload a preview deploy → enable its public
# preview URL → comment it on the PR. Talks to the documented public API only.
set -euo pipefail

API="${NGRIS_API_URL:-https://api.ngris.com}"
APP="${NGRIS_APP:?app name is required}"
DIR="${NGRIS_DIR:-dist}"
: "${NGRIS_API_KEY:?api-key is required (store it as a repo secret, e.g. NGRIS_API_KEY)}"

auth=(-H "X-API-Key: ${NGRIS_API_KEY}")
ct_json=(-H "Content-Type: application/json")

die() { echo "::error::$*"; exit 1; }
for bin in curl jq zip; do command -v "$bin" >/dev/null || die "'$bin' is required (present on ubuntu-latest runners)"; done

# --- optional build -------------------------------------------------------
if [ -n "${NGRIS_BUILD_COMMAND:-}" ]; then
  echo "::group::build: ${NGRIS_BUILD_COMMAND}"
  bash -lc "${NGRIS_BUILD_COMMAND}"
  echo "::endgroup::"
fi
[ -d "$DIR" ] || die "deploy directory '$DIR' not found — set 'dir' to your build output (e.g. dist, build, out)."

# --- zip the build output (contents at the archive root) ------------------
work="$(mktemp -d)"; zipf="$work/site.zip"
( cd "$DIR" && zip -qr "$zipf" . )
echo "packaged $DIR ($(du -h "$zipf" | cut -f1))"

# --- 1) create-or-get the application by name -----------------------------
app_uuid="$(curl -fsS "${auth[@]}" "$API/api/applications" \
  | jq -r --arg n "$APP" '.applications[]? | select(.name==$n) | .uuid' | head -n1)"
if [ -z "$app_uuid" ] || [ "$app_uuid" = "null" ]; then
  echo "creating application '$APP'…"
  app_uuid="$(curl -fsS "${auth[@]}" "${ct_json[@]}" -X POST "$API/api/applications" \
    -d "$(jq -nc --arg n "$APP" '{name:$n, source:"upload"}')" | jq -r '.uuid')"
fi
[ -n "$app_uuid" ] && [ "$app_uuid" != "null" ] || die "could not create or find application '$APP' (check the API key + its account permissions)."
echo "application: $APP ($app_uuid)"

# --- 2) upload the build as a new deploy ----------------------------------
label="${GITHUB_SHA:-manual}"; label="${label:0:12}"
deploy_uuid="$(curl -fsS "${auth[@]}" -X POST "$API/api/applications/$app_uuid/deploys" \
  -F "file=@$zipf" -F "version=$label" | jq -r '.uuid')"
[ -n "$deploy_uuid" ] && [ "$deploy_uuid" != "null" ] || die "deploy upload failed."
echo "deploy: $deploy_uuid — building…"

# --- 3) poll until the build is ready -------------------------------------
status=""
for _ in $(seq 1 90); do
  status="$(curl -fsS "${auth[@]}" "$API/api/applications/$app_uuid/deploys" \
    | jq -r --arg d "$deploy_uuid" '.deploys[]? | select(.uuid==$d) | .status')"
  case "$status" in
    ready|superseded) break ;;
    failed) die "build failed — see the deploy logs in the ngris dashboard." ;;
  esac
  sleep 5
done
[ "$status" = "ready" ] || [ "$status" = "superseded" ] || die "build did not become ready in time (last status: ${status:-unknown})."
echo "build ready."

# --- 4) enable the public preview URL for this deploy ---------------------
preview_url="$(curl -fsS "${auth[@]}" -X POST "$API/api/applications/$app_uuid/deploys/$deploy_uuid/preview" | jq -r '.preview_url')"
[ -n "$preview_url" ] && [ "$preview_url" != "null" ] || die "could not enable the preview URL."

echo "preview-url=$preview_url"  >> "${GITHUB_OUTPUT:-/dev/stdout}"
echo "deploy-uuid=$deploy_uuid"  >> "${GITHUB_OUTPUT:-/dev/stdout}"
echo "::notice title=ngris preview::$preview_url"
echo "🔗 Preview deployed: $preview_url"

# --- 5) comment (upsert) on the PR ----------------------------------------
if [ "${NGRIS_COMMENT:-true}" = "true" ] && [ "${GH_EVENT_NAME:-}" = "pull_request" ] && [ -n "${GH_TOKEN:-}" ]; then
  pr="$(jq -r '.pull_request.number // .number // empty' "${GH_EVENT_PATH}")"
  if [ -n "$pr" ]; then
    ghapi="${GH_API_URL:-https://api.github.com}"; repo="${GH_REPOSITORY}"
    gh_auth=(-H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json")
    marker="<!-- ngris-preview -->"
    body="$marker
### ⚡ ngris preview deployed
**🔗 $preview_url**

| | |
|---|---|
| App | \`$APP\` |
| Commit | \`$label\` |
| Deploy | \`$deploy_uuid\` |

_Every push updates this preview. Behind the ngris edge (WAF, auth, rate-limit configurable per endpoint)._"
    payload="$(jq -nc --arg b "$body" '{body:$b}')"
    cid="$(curl -fsS "${gh_auth[@]}" "$ghapi/repos/$repo/issues/$pr/comments?per_page=100" \
      | jq -r --arg m "$marker" 'map(select(.body|type=="string" and contains($m)))[0].id // empty')"
    if [ -n "$cid" ]; then
      curl -fsS "${gh_auth[@]}" -X PATCH "$ghapi/repos/$repo/issues/comments/$cid" -d "$payload" >/dev/null && echo "updated PR #$pr comment"
    else
      curl -fsS "${gh_auth[@]}" -X POST  "$ghapi/repos/$repo/issues/$pr/comments"       -d "$payload" >/dev/null && echo "commented on PR #$pr"
    fi
  fi
fi
