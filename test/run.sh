#!/usr/bin/env bash
# Hermetic tests for entrypoint.sh. Each case runs the action against a local mock of
# the ngris API and the GitHub comments API (test/mock_api.py): no network, no account.
# Needs bash, curl, jq, zip and python3 (all on ubuntu-latest).
#
#   bash test/run.sh                      # test ./entrypoint.sh
#   ENTRYPOINT=/path/to/old.sh bash test/run.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="${ENTRYPOINT:-$here/../entrypoint.sh}"
tmp="$(mktemp -d)"

SHA_A=aaaaaaaaaaaa0000000000000000000000000000
SHA_B=bbbbbbbbbbbb0000000000000000000000000000
SHA_C=cccccccccccc0000000000000000000000000000

APP_SITE='{"uuid":"app-site","name":"site","preview_visibility":"private","require_manual_promotion":false,"current_deploy_uuid":"dep-live"}'
DEP_LIVE='{"uuid":"dep-live","app_uuid":"app-site","version":1,"version_label":"prod-000000000000","status":"ready","preview_enabled":false,"auto_activate":true}'
# dep UUID VERSION LABEL PREVIEW — a deploy row of app-site for a seed.
dep() { printf '{"uuid":"%s","app_uuid":"app-site","version":%s,"version_label":"%s","status":"ready","preview_enabled":%s,"auto_activate":false}' "$1" "$2" "$3" "$4"; }
pr_event() { printf '{"action":"%s","number":%s,"pull_request":{"number":%s},"repository":{"default_branch":"main"}}' "$2" "$1" "$1"; }
PUSH_EVENT='{"repository":{"default_branch":"main"}}'

case_n=0; case_name=""; cdir=""; mock_pid=""; MOCK=""; RC=0
passed=0; failures=()

# start CASE_NAME SEED_JSON — a fresh mock + working directory for one case.
start() {
  case_n=$((case_n + 1)); case_name="$1"; cdir="$tmp/$case_n"
  mkdir -p "$cdir/site"
  echo '<h1>hello</h1>' >"$cdir/site/index.html"
  printf '%s' "$2" >"$cdir/seed.json"
  python3 "$here/mock_api.py" "$cdir/seed.json" "$cdir/port" &
  mock_pid=$!
  for _ in $(seq 1 200); do [ -s "$cdir/port" ] && break; sleep 0.05; done
  [ -s "$cdir/port" ] || { echo "mock did not start"; exit 2; }
  MOCK="http://127.0.0.1:$(cat "$cdir/port")"
  echo "- $case_name"
}
stop() { kill "$mock_pid" 2>/dev/null; wait "$mock_pid" 2>/dev/null; }

# run EVENT_NAME EVENT_JSON [VAR=value…] — runs the action in a clean environment
# (later VAR=value pairs override the defaults); output in $cdir/out, exit code in RC.
run() {
  local ev="$1" evjson="$2"; shift 2
  printf '%s' "$evjson" >"$cdir/event.json"
  : >"$cdir/gh_output"
  env -i PATH="$PATH" HOME="$HOME" TMPDIR="$cdir" \
    NGRIS_API_URL="$MOCK" NGRIS_API_KEY=ngk_test NGRIS_APP=site NGRIS_DIR="$cdir/site" NGRIS_COMMENT=true \
    GH_EVENT_NAME="$ev" GH_EVENT_PATH="$cdir/event.json" GH_REPOSITORY=acme/site GH_API_URL="$MOCK" GH_TOKEN=ghs_test \
    GITHUB_OUTPUT="$cdir/gh_output" GITHUB_SHA="$SHA_A" GITHUB_REF=refs/pull/7/merge GITHUB_REF_NAME=7/merge \
    "$@" timeout 120 bash "$ENTRYPOINT" >>"$cdir/out" 2>&1
  RC=$?
}

# st JQ — a value from the mock's state.
st() { curl -fsS "$MOCK/__state" | jq -r "$1"; }

# check DESCRIPTION COMMAND… — one assertion.
check() {
  local desc="$1"; shift
  if "$@"; then
    passed=$((passed + 1))
  else
    failures+=("$case_name: $desc")
    echo "    FAIL: $desc"
    sed 's/^/      | /' "$cdir/out" 2>/dev/null | tail -n 15
  fi
}
is() { [ "$1" = "$2" ] || { echo "      expected '$2', got '$1'"; return 1; }; }
isnt() { [ "$1" != "$2" ] || { echo "      did not expect '$2'"; return 1; }; }
has() { grep -qF -- "$2" "$1" || { echo "      '$2' not found in $(basename "$1")"; return 1; }; }
lacks() { ! grep -qF -- "$2" "$1" || { echo "      '$2' found in $(basename "$1")"; return 1; }; }

# ---------------------------------------------------------------------------
start "a pull request run uploads a not-live candidate; production is unchanged" \
  "{\"apps\":[$APP_SITE],\"deploys\":[$DEP_LIVE]}"
run pull_request "$(pr_event 7 opened)"
check "exits 0" is "$RC" 0
check "uploads with activate=false" is "$(st '.uploads[-1].fields.activate // "absent"')" false
check "the live deploy is unchanged" is "$(st '.apps[0].current_deploy_uuid')" dep-live
check "labels the deploy with the PR" is "$(st '.deploys[-1].version_label')" pr-7-aaaaaaaaaaaa
check "turns the new deploy's preview on" is "$(st '.deploys[-1].preview_enabled')" true
check "sets the preview-url output" has "$cdir/gh_output" "preview-url=https://"
stop

start "the app is found by its exact name past the first page of the list" \
  '{"max_page_size":2,"apps":[
     {"uuid":"app-site","name":"site","preview_visibility":"private"},
     {"uuid":"app-docs","name":"site-docs","preview_visibility":"private"},
     {"uuid":"app-my","name":"my-site","preview_visibility":"private"},
     {"uuid":"app-blog","name":"site-blog","preview_visibility":"private"},
     {"uuid":"app-v2","name":"site-v2","preview_visibility":"private"}]}'
run pull_request "$(pr_event 7 opened)"
check "exits 0" is "$RC" 0
check "uploads to the app named exactly 'site'" is "$(st '.uploads[0].app_uuid // "none"')" app-site
check "does not try to create the app" is "$(st '[.calls[] | select(. == "POST /api/applications")] | length')" 0
check "filters the list by name" is "$(st '[.calls[] | select(startswith("GET /api/applications?q=site&"))] | length > 0')" true
stop

start "a 409 at create (a parallel run created the app) looks the app up again" \
  '{"race_create":true}'
run pull_request "$(pr_event 7 opened)"
check "exits 0" is "$RC" 0
check "only one app exists" is "$(st '.apps | length')" 1
check "uploads to that app" is "$(st '.uploads[0].app_uuid == .apps[0].uuid')" true
stop

start "a 409 with no exact-name match stops with a clear message" \
  '{"apps":[{"uuid":"app-site","name":"Site","preview_visibility":"private"}]}'
run pull_request "$(pr_event 7 opened)"
check "exits non-zero" isnt "$RC" 0
check "uploads nothing" is "$(st '.uploads | length')" 0
check "says to set the exact name" has "$cdir/out" "Set 'app' to the existing application's exact name"
stop

start "each push to a PR replaces its previous preview, so the preview limit is not used up" \
  "{\"preview_cap\":3,\"apps\":[$APP_SITE],\"deploys\":[$DEP_LIVE,
     $(dep dep-pr70 2 pr-70-dddddddddddd true),
     $(dep dep-pr7-hand 3 pr-7-by-hand true)]}"
for sha in "$SHA_A" "$SHA_B" "$SHA_C"; do
  run pull_request "$(pr_event 7 synchronize)" GITHUB_SHA="$sha"
  check "push ${sha:0:4}… exits 0" is "$RC" 0
done
check "one preview of PR 7 made by the action is on" \
  is "$(st '[.deploys[] | select(.preview_enabled and (.version_label | test("^pr-7-[0-9a-f]+$")))] | map(.version_label) | join(",")')" pr-7-cccccccccccc
check "PR 70's preview is untouched" is "$(st '.deploys[] | select(.uuid == "dep-pr70") | .preview_enabled')" true
check "a preview not made by the action is untouched" is "$(st '.deploys[] | select(.uuid == "dep-pr7-hand") | .preview_enabled')" true
check "the live deploy is unchanged" is "$(st '.apps[0].current_deploy_uuid')" dep-live
stop

start "closing a PR turns its preview off and deploys nothing" \
  "{\"apps\":[$APP_SITE],\"deploys\":[$DEP_LIVE,
     $(dep dep-pr7 2 pr-7-aaaaaaaaaaaa true),
     $(dep dep-pr8 3 pr-8-bbbbbbbbbbbb true)]}"
run pull_request "$(pr_event 7 closed)" NGRIS_BUILD_COMMAND="touch $cdir/built"
check "exits 0" is "$RC" 0
check "uploads nothing" is "$(st '.uploads | length')" 0
check "does not run the build" is "$([ -e "$cdir/built" ] && echo ran || echo skipped)" skipped
check "PR 7's preview is off" is "$(st '.deploys[] | select(.uuid == "dep-pr7") | .preview_enabled')" false
check "PR 8's preview is still on" is "$(st '.deploys[] | select(.uuid == "dep-pr8") | .preview_enabled')" true
stop

start "a push to the default branch deploys to production" \
  "{\"apps\":[$APP_SITE],\"deploys\":[$DEP_LIVE,$(dep dep-prod-old 2 prod-bbbbbbbbbbbb true)]}"
run push "$PUSH_EVENT" GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main
check "exits 0" is "$RC" 0
check "uploads without an activate field" is "$(st '.uploads[0].fields.activate // "absent"')" absent
check "the new deploy is live" is "$(st '.apps[0].current_deploy_uuid == .deploys[-1].uuid')" true
check "labels the deploy as production" is "$(st '.deploys[-1].version_label')" prod-aaaaaaaaaaaa
check "the previous production preview is off" is "$(st '.deploys[] | select(.uuid == "dep-prod-old") | .preview_enabled')" false
stop

start "a push to another branch is a preview" \
  "{\"apps\":[$APP_SITE],\"deploys\":[$DEP_LIVE]}"
run push "$PUSH_EVENT" GITHUB_REF=refs/heads/feature/x GITHUB_REF_NAME=feature/x
check "exits 0" is "$RC" 0
check "uploads with activate=false" is "$(st '.uploads[0].fields.activate // "absent"')" false
check "the live deploy is unchanged" is "$(st '.apps[0].current_deploy_uuid')" dep-live
check "labels the deploy with the branch" is "$(st '.deploys[-1].version_label')" ref-feature/x-aaaaaaaaaaaa
stop

start "a manual run is a preview unless production is true" \
  "{\"apps\":[$APP_SITE],\"deploys\":[$DEP_LIVE]}"
run workflow_dispatch "$PUSH_EVENT" GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main
check "auto: exits 0" is "$RC" 0
check "auto: uploads with activate=false" is "$(st '.uploads[0].fields.activate // "absent"')" false
check "auto: the live deploy is unchanged" is "$(st '.apps[0].current_deploy_uuid')" dep-live
run workflow_dispatch "$PUSH_EVENT" GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main NGRIS_PRODUCTION=true
check "true: exits 0" is "$RC" 0
check "true: uploads without an activate field" is "$(st '.uploads[1].fields.activate // "absent"')" absent
check "true: the new deploy is live" is "$(st '.apps[0].current_deploy_uuid == .deploys[-1].uuid')" true
stop

start "production: true is refused on a pull request" \
  "{\"apps\":[$APP_SITE],\"deploys\":[$DEP_LIVE]}"
run pull_request "$(pr_event 7 synchronize)" NGRIS_PRODUCTION=true
check "exits non-zero" isnt "$RC" 0
check "uploads nothing" is "$(st '.uploads | length')" 0
check "says why" has "$cdir/out" "a pull request never changes production"
run pull_request_target "$(pr_event 7 synchronize)" NGRIS_PRODUCTION=true
check "pull_request_target: exits non-zero" isnt "$RC" 0
check "pull_request_target: uploads nothing" is "$(st '.uploads | length')" 0
stop

start "an unknown production value is refused" \
  "{\"apps\":[$APP_SITE],\"deploys\":[$DEP_LIVE]}"
run push "$PUSH_EVENT" GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main NGRIS_PRODUCTION=yes
check "exits non-zero" isnt "$RC" 0
check "uploads nothing" is "$(st '.uploads | length')" 0
stop

start "an app that requires manual promotion keeps its production deploy a candidate" \
  "{\"apps\":[{\"uuid\":\"app-site\",\"name\":\"site\",\"preview_visibility\":\"private\",\"require_manual_promotion\":true,\"current_deploy_uuid\":\"dep-live\"}],\"deploys\":[$DEP_LIVE]}"
run push "$PUSH_EVENT" GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main
check "exits 0" is "$RC" 0
check "uploads without an activate field" is "$(st '.uploads[0].fields.activate // "absent"')" absent
check "the live deploy is unchanged" is "$(st '.apps[0].current_deploy_uuid')" dep-live
check "says to promote it" has "$cdir/out" "requires manual promotion"
stop

start "the PR comment says the preview is not live and who can open it" \
  "{\"apps\":[$APP_SITE],\"deploys\":[$DEP_LIVE]}"
run pull_request "$(pr_event 7 opened)"
st '.comments[0].body // ""' >"$cdir/comment"
check "exits 0" is "$RC" 0
check "comments once" is "$(st '.comments | length')" 1
check "says it is not live" has "$cdir/comment" "Not live: production is unchanged."
check "says it is private" has "$cdir/comment" "Private: only members of your ngris account can open it"
check "does not claim endpoint protection" lacks "$cdir/comment" "WAF"
stop

start "at the plan's preview limit the API's message is shown" \
  "{\"preview_cap\":1,\"apps\":[$APP_SITE],\"deploys\":[$DEP_LIVE,$(dep dep-pr8 2 pr-8-bbbbbbbbbbbb true)]}"
run pull_request "$(pr_event 7 opened)"
check "exits non-zero" isnt "$RC" 0
check "shows the limit" has "$cdir/out" "limit of 1 live preview"
check "the live deploy is unchanged" is "$(st '.apps[0].current_deploy_uuid')" dep-live
stop

start "the build command gets no API key and no GitHub token" \
  "{\"apps\":[$APP_SITE],\"deploys\":[$DEP_LIVE]}"
run pull_request "$(pr_event 7 opened)" NGRIS_BUILD_COMMAND="env > $cdir/build-env"
check "exits 0" is "$RC" 0
check "the build ran" is "$([ -s "$cdir/build-env" ] && echo ran || echo skipped)" ran
check "no ngris API key in the build" lacks "$cdir/build-env" "ngk_test"
check "no GitHub token in the build" lacks "$cdir/build-env" "ghs_test"
check "the preview was still uploaded" is "$(st '.uploads | length')" 1
stop

# ---------------------------------------------------------------------------
echo
echo "$passed passed, ${#failures[@]} failed"
if [ "${#failures[@]}" -gt 0 ]; then
  printf '  %s\n' "${failures[@]}"
  exit 1
fi
