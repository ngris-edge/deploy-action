#!/usr/bin/env bash
# ngris deploy-action — build → zip → upload a deploy → turn on its preview URL →
# comment it on the PR. Talks to the documented public API only.
#
# A pull-request run never changes production: it uploads a NOT-live candidate
# (activate=false) and gives it a preview URL. Only a push to the repository's
# default branch, or a non-PR run with `production: true`, uploads a production
# deploy (live at once, unless the app requires manual promotion).
set -euo pipefail

API="${NGRIS_API_URL:-https://api.ngris.com}"
APP="${NGRIS_APP:?app name is required}"
DIR="${NGRIS_DIR:-dist}"
PRODUCTION="${NGRIS_PRODUCTION:-auto}"
: "${NGRIS_API_KEY:?api-key is required (store it as a repo secret, e.g. NGRIS_API_KEY)}"

# List paging: the API clamps page_size to its own maximum (200) and answers with the
# size it used, which the paging below follows. It serves at most 100000 rows of a list
# (500 pages of 200).
PAGE_SIZE=200
MAX_PAGES=500

auth=(-H "X-API-Key: ${NGRIS_API_KEY}")
ct_json=(-H "Content-Type: application/json")

die() { echo "::error::$*"; exit 1; }
for bin in curl jq zip; do command -v "$bin" >/dev/null || die "'$bin' is required (present on ubuntu-latest runners)"; done

# The API stores application names trimmed; match them the same way.
APP="$(printf '%s' "$APP" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
[ -n "$APP" ] || die "app name is required"
work="$(mktemp -d)"

# --- API helpers ------------------------------------------------------------
# api METHOD URL [curl args…] — one ngris API call. Sets API_STATUS (the HTTP status,
# 000 when there was no answer) and API_BODY. Never exits: each caller decides.
api() {
  local method="$1" url="$2"; shift 2
  : >"$work/body"
  API_STATUS="$(curl -sS -o "$work/body" -w '%{http_code}' -X "$method" "${auth[@]}" "$@" "$url")" || API_STATUS=000
  API_BODY="$(cat "$work/body")"
}
# fail_api WHAT — stop with the API's own error message from the last call.
fail_api() {
  local msg
  msg="$(jq -r '.error // .message // empty' <<<"$API_BODY" 2>/dev/null | head -c 300)" || msg=""
  die "$1 (HTTP $API_STATUS)${msg:+: $msg}"
}
# paged URL ITEMS FILTER [jq args…] — reads every page of a paged list
# (?page=&page_size= → {ITEMS: […], total, page, page_size}) and puts the lines the jq
# FILTER prints for each page into the array PAGED.
paged() {
  local url="$1" items="$2" filter="$3" page=1 n size total
  shift 3
  PAGED=()
  while :; do
    api GET "$url" -G --data-urlencode "page=$page" --data-urlencode "page_size=$PAGE_SIZE"
    [ "$API_STATUS" = 200 ] || fail_api "could not list the $items"
    mapfile -t -O "${#PAGED[@]}" PAGED < <(jq -r "$@" "$filter" <<<"$API_BODY")
    n="$(jq -r --arg k "$items" '(.[$k] // []) | length' <<<"$API_BODY")"
    size="$(jq -r '.page_size // 0' <<<"$API_BODY")"
    total="$(jq -r '.total // 0' <<<"$API_BODY")"
    if [ "$n" -eq 0 ] || [ $((page * size)) -ge "$total" ]; then return 0; fi
    page=$((page + 1))
    [ "$page" -le "$MAX_PAGES" ] || die "the $items list is too long to read."
  done
}
# find_app — sets app_uuid (and app_preview_visibility) to the application named
# exactly $APP, or "" when there is none. q narrows the list on the server to names
# that contain $APP; the exact match is made here, over every page.
find_app() {
  paged "$API/api/applications?q=$(jq -rn --arg v "$APP" '$v | @uri')" applications \
    '.applications[]? | select(.name == $n) | "\(.uuid) \(.preview_visibility // "")"' --arg n "$APP"
  app_uuid=""; app_preview_visibility=""
  if [ "${#PAGED[@]}" -gt 0 ]; then read -r app_uuid app_preview_visibility <<<"${PAGED[0]}"; fi
}
# revoke_stream_previews KEEP — turns off the preview URL of every deploy of this run's
# stream (labelled "<stream>-<commit>") except the deploy KEEP, so a PR holds one
# preview at a time and earlier pushes do not use up the account's preview limit.
revoke_stream_previews() {
  local id
  paged "$API/api/applications/$app_uuid/deploys" deploys \
    '.deploys[]? | select(.preview_enabled == true and .uuid != $keep)
      | select((.version_label // "") as $l | ($l | startswith($p)) and ($l[($p | length):] | test("^[0-9a-f]{7,40}$")))
      | .uuid' --arg p "$stream-" --arg keep "$1"
  for id in "${PAGED[@]}"; do
    api DELETE "$API/api/applications/$app_uuid/deploys/$id/preview"
    case "$API_STATUS" in
      2??|404) echo "turned off the earlier preview of deploy $id" ;;
      *) echo "::warning::could not turn off the earlier preview of deploy $id (HTTP $API_STATUS)" ;;
    esac
  done
}

# --- 0) what this run deploys -------------------------------------------------
event="${GH_EVENT_NAME:-}"
event_field() { if [ -n "${GH_EVENT_PATH:-}" ] && [ -f "$GH_EVENT_PATH" ]; then jq -r "$1" "$GH_EVENT_PATH"; fi; }
is_pr=false; pr=""; pr_action=""
case "$event" in
  pull_request*)
    is_pr=true
    pr="$(event_field '.pull_request.number // .number // empty')"
    pr_action="$(event_field '.action // empty')"
    [[ "$pr" =~ ^[0-9]+$ ]] || die "could not read the pull request number from the event."
    ;;
esac

# production: auto (default) = only a push to the default branch; true = this run
# (never a pull request); false = never.
production=false
case "$(printf '%s' "$PRODUCTION" | tr '[:upper:]' '[:lower:]')" in
  auto|"")
    default_branch="$(event_field '.repository.default_branch // empty')"
    if [ "$event" = push ] && [ -n "$default_branch" ] && [ "${GITHUB_REF:-}" = "refs/heads/$default_branch" ]; then
      production=true
    fi
    ;;
  true)
    [ "$is_pr" = false ] || die "'production: true' is not allowed on a pull request run — a pull request never changes production."
    production=true
    ;;
  false) ;;
  *) die "'production' must be auto, true or false (got '$PRODUCTION')." ;;
esac

# Each deploy is labelled "<stream>-<commit>". The stream is the pull request
# (pr-<number>), production (prod), or the branch/tag of any other run (ref-<name>).
if [ "$is_pr" = true ]; then
  stream="pr-$pr"
elif [ "$production" = true ]; then
  stream="prod"
else
  ref="$(printf '%s' "${GITHUB_REF_NAME:-}" | tr -c 'A-Za-z0-9._/-' '-' | cut -c1-40)"
  stream="ref-${ref:-run}"
fi
sha="${GITHUB_SHA:-}"; sha="${sha:0:12}"
if [[ "$sha" =~ ^[0-9a-f]{7,}$ ]]; then label="$stream-$sha"; else sha="manual"; label="manual"; fi

# --- a closed pull request: turn its preview off, deploy nothing ------------
if [ "$is_pr" = true ] && [ "$pr_action" = closed ]; then
  find_app
  if [ -n "$app_uuid" ]; then
    revoke_stream_previews ""
    echo "PR #$pr is closed: its preview is off."
  else
    echo "application '$APP' not found: nothing to turn off."
  fi
  exit 0
fi

if [ "$production" = true ]; then
  echo "production deploy ($label)"
else
  echo "preview deploy ($label): not live, production is unchanged"
fi

# --- optional build -------------------------------------------------------
if [ -n "${NGRIS_BUILD_COMMAND:-}" ]; then
  echo "::group::build: ${NGRIS_BUILD_COMMAND}"
  bash -lc "${NGRIS_BUILD_COMMAND}"
  echo "::endgroup::"
fi
[ -d "$DIR" ] || die "deploy directory '$DIR' not found — set 'dir' to your build output (e.g. dist, build, out)."

# --- zip the build output (contents at the archive root) ------------------
zipf="$work/site.zip"
( cd "$DIR" && zip -qr "$zipf" . )
echo "packaged $DIR ($(du -h "$zipf" | cut -f1))"

# --- 1) find the application by its exact name, or create it --------------
find_app
if [ -z "$app_uuid" ]; then
  echo "creating application '$APP'…"
  api POST "$API/api/applications" "${ct_json[@]}" -d "$(jq -nc --arg n "$APP" '{name:$n, source:"upload"}')"
  case "$API_STATUS" in
    2??)
      app_uuid="$(jq -r '.uuid // empty' <<<"$API_BODY")"
      app_preview_visibility="$(jq -r '.preview_visibility // empty' <<<"$API_BODY")"
      ;;
    409)
      # It exists after all (a parallel run created it first): look it up again.
      find_app
      [ -n "$app_uuid" ] || die "an application named '$APP' already exists, but none has exactly this name (names that differ only in letter case count as the same). Set 'app' to the existing application's exact name."
      ;;
    *) fail_api "could not create application '$APP' (check the API key and its account permissions)" ;;
  esac
fi
[ -n "$app_uuid" ] || die "could not create or find application '$APP' (check the API key + its account permissions)."
echo "application: $APP ($app_uuid)"

# --- 2) upload the build as a new deploy ----------------------------------
# A preview sends activate=false: the deploy is built as a not-live candidate and the
# live version stays as it is. A production deploy sends no activate field, so the
# app's own deploy policy applies (live at once, or a candidate to promote by hand).
upload=(-F "file=@$zipf" -F "version=$label")
[ "$production" = true ] || upload+=(-F "activate=false")
api POST "$API/api/applications/$app_uuid/deploys" "${upload[@]}"
case "$API_STATUS" in 2??) ;; *) fail_api "deploy upload failed" ;; esac
deploy_uuid="$(jq -r '.uuid // empty' <<<"$API_BODY")"
[ -n "$deploy_uuid" ] || die "deploy upload failed."
if [ "$production" = true ] && [ "$(jq -r '.auto_activate' <<<"$API_BODY")" = false ]; then
  echo "this application requires manual promotion: promote deploy $deploy_uuid from its Deploys tab in the ngris dashboard to put it live."
fi
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

# --- 4) one preview per stream: turn the earlier ones off, then this one on --
revoke_stream_previews "$deploy_uuid"
api POST "$API/api/applications/$app_uuid/deploys/$deploy_uuid/preview" "${ct_json[@]}"
case "$API_STATUS" in 2??) ;; *) fail_api "could not turn on the preview URL" ;; esac
preview_url="$(jq -r '.preview_url // empty' <<<"$API_BODY")"
[ -n "$preview_url" ] || die "could not turn on the preview URL."

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
    case "${app_preview_visibility:-}" in
      public)  visibility=" Public: anyone with the link can open it." ;;
      private) visibility=" Private: only members of your ngris account can open it, after signing in to ngris." ;;
      *)       visibility="" ;;
    esac
    body="$marker
### ⚡ ngris preview deployed
**🔗 $preview_url**

| | |
|---|---|
| App | \`$APP\` |
| Commit | \`$sha\` |
| Deploy | \`$deploy_uuid\` |

_Not live: production is unchanged. Every push replaces this preview.${visibility}_"
    payload="$(jq -nc --arg b "$body" '{body:$b}')"
    cid="$(curl -fsS "${gh_auth[@]}" "$ghapi/repos/$repo/issues/$pr/comments?per_page=100" \
      | jq -r --arg m "$marker" 'map(select(.body|type=="string" and contains($m)))[0].id // empty')"
    if [ -n "$cid" ]; then
      curl -fsS "${gh_auth[@]}" "${ct_json[@]}" -X PATCH "$ghapi/repos/$repo/issues/comments/$cid" -d "$payload" >/dev/null && echo "updated PR #$pr comment"
    else
      curl -fsS "${gh_auth[@]}" "${ct_json[@]}" -X POST  "$ghapi/repos/$repo/issues/$pr/comments"       -d "$payload" >/dev/null && echo "commented on PR #$pr"
    fi
  fi
fi
