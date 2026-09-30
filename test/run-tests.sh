#!/usr/bin/env bash
# Runs the action's verify script against stubbed `gh` and `curl`.
#
# Each case sets the GitHub context the action would see, the pull requests
# GitHub reports for the commit, and the PP verify response, then asserts on
# the exit code, the outputs, and the request body sent to PP.
#
# Usage: test/run-tests.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The script is the `run: |` block of the only step, dedented.
SCRIPT="$WORK/verify.sh"
awk '
  /^      run: \|$/ { inrun = 1; next }
  inrun { sub(/^        /, ""); print }
' "$ROOT/action.yml" > "$SCRIPT"
if ! grep -q 'receipts/verify' "$SCRIPT"; then
  echo "could not extract the run block from action.yml" >&2
  exit 1
fi
# Expressions the runner would substitute inside the script body.
sed -i.bak 's/\${{ github.repository }}/acme\/web/g' "$SCRIPT"
# macOS ships bash 3.2; CI runs the script unmodified on bash 5.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  sed -i.bak 's/\${PP_REPOSITORY,,}/$(echo "$PP_REPOSITORY" | tr "[:upper:]" "[:lower:]")/' "$SCRIPT"
fi

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$STUB_DIR/gh.log"
if [ "$1" = "api" ] && [[ "$2" == repos/*/commits/*/pulls ]]; then
  if [ -n "${STUB_PULLS_FAIL:-}" ]; then echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; fi
  cat "$STUB_DIR/pulls.json"
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  case "$*" in
    *isDraft*) echo "${STUB_IS_DRAFT:-false}" ;;
    *files*) printf 'src/app.ts\ndeploy/prod.yml\n' ;;
  esac
  exit 0
fi
echo "unexpected gh call: $*" >&2
exit 1
STUB
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_DIR/curl.log"
while [ $# -gt 0 ]; do
  if [ "$1" = "-d" ]; then printf '%s' "$2" > "$STUB_DIR/request.json"; fi
  shift
done
cat "$STUB_DIR/response.json"
printf '\n%s' "${STUB_STATUS:-200}"
STUB
chmod +x "$WORK/bin/gh" "$WORK/bin/curl"

PASS=0
FAIL=0
CASE=""
CASE_DIR=""
EXIT_CODE=0

# run_case <name> [VAR=value ...]; stdin is the PP response body.
run_case() {
  CASE="$1"; shift
  CASE_DIR="$WORK/case-$((PASS + FAIL + 1))"
  mkdir -p "$CASE_DIR"
  cat > "$CASE_DIR/response.json"
  [ -f "$CASE_DIR/pulls.json" ] || echo '[]' > "$CASE_DIR/pulls.json"
  if [ -n "${PULLS:-}" ]; then printf '%s' "$PULLS" > "$CASE_DIR/pulls.json"; fi
  : > "$CASE_DIR/outputs"
  (
    export PATH="$WORK/bin:$PATH" STUB_DIR="$CASE_DIR" GITHUB_OUTPUT="$CASE_DIR/outputs"
    export PP_BASE_URL=https://pp.test PP_API_KEY=pp_live_test PP_REQUEST_CREATE_TOKEN=
    export PP_ENVIRONMENT=production PP_CAPABILITY=deploy:production
    export PP_ALLOW_CARRY_FORWARD= PP_REDEEM= PP_FAIL_ON_MISSING=true PP_PROTECTED_PATHS='^(deploy/|\.github/workflows/)'
    export PP_FAIL_OPEN_TIMEOUT=30 PP_FAIL_MODE=closed PP_PRODUCTION_ENVIRONMENTS=production,prod,live
    export PP_POST_COMMENT=false PP_REPOSITORY=Acme/Web
    export PP_PR_NUMBER= PP_PR_HEAD_SHA= PP_PR_BASE_SHA= PP_PR_TITLE=
    export PP_MODE=auto PP_EVENT_NAME=push PP_SHA=mergesha0000000000 PP_REF=refs/heads/main
    export PP_RUN_ID=4242 GH_TOKEN=ghs_test
    for assignment in "$@"; do export "$assignment"; done
    bash "$SCRIPT"
  ) > "$CASE_DIR/stdout" 2>&1
  EXIT_CODE=$?
  PULLS=""
}

output() { # value of a GITHUB_OUTPUT key; like the runner, the last write wins
  awk -v key="$1" '
    $0 == key "<<__PP_EOF__" { grab = 1; value = ""; first = 1; next }
    grab && $0 == "__PP_EOF__" { grab = 0; next }
    grab { value = first ? $0 : value "\n" $0; first = 0 }
    END { print value }
  ' "$CASE_DIR/outputs"
}
request() { jq -c "$1" "$CASE_DIR/request.json" 2>/dev/null; }

check() { # check <description> <actual> <expected>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL [$CASE] $1: expected '$3', got '$2'"
    sed 's/^/    | /' "$CASE_DIR/stdout" | tail -20
  fi
}
no_request() { if [ -f "$CASE_DIR/request.json" ]; then echo sent; else echo none; fi; }

MERGED='[
  {"number": 7, "merged_at": null, "merge_commit_sha": "othersha", "base": {"ref": "main", "sha": "b0"}, "head": {"sha": "unmerged"}},
  {"number": 12, "merged_at": "2026-09-26T10:00:00Z", "merge_commit_sha": "mergesha0000000000", "base": {"ref": "main", "sha": "base12"}, "head": {"sha": "approvedhead12"}}
]'
VALID='{"valid": true, "receiptId": "rcpt_1", "decision": "APPROVED", "requestId": "req_1"}'

# --- deploy mode: the merged PR's approval is verified and redeemed ---------
PULLS="$MERGED" run_case "push deploys merged PR" <<<"$VALID"
check "exit" "$EXIT_CODE" 0
check "mode" "$(output mode)" deploy
check "approved" "$(output approved)" true
check "pr-number" "$(output pr-number)" 12
check "pr-head-sha" "$(output pr-head-sha)" approvedhead12
check "scope" "$(request .scope)" '{"repo":"acme/web","prNumber":12,"headSha":"approvedhead12","env":"production","capability":"deploy:production"}'
check "redeem" "$(request .redeem)" true
check "failOnMissing" "$(request .failOnMissing)" true
check "no draft lookup" "$(grep -c isDraft "$CASE_DIR/gh.log")" 0
check "no title outside a PR event" "$(request 'has("prTitle")')" false

PULLS="$MERGED" run_case "workflow_dispatch deploys merged PR" PP_EVENT_NAME=workflow_dispatch <<<"$VALID"
check "exit" "$EXIT_CODE" 0
check "pr-number" "$(output pr-number)" 12
check "redeem" "$(request .redeem)" true

PULLS="$MERGED" run_case "explicit deploy mode with redeem true" PP_MODE=deploy PP_REDEEM=true <<<"$VALID"
check "exit" "$EXIT_CODE" 0
check "redeem" "$(request .redeem)" true

# --- deploy mode fails closed -----------------------------------------------
PULLS='[]' run_case "direct push has no PR" <<<"$VALID"
check "exit" "$EXIT_CODE" 1
check "error" "$(output error-code)" PP_NO_MERGED_PR
check "approved" "$(output approved)" false
check "no PP call" "$(no_request)" none

PULLS='[{"number": 3, "merged_at": "2026-09-26T10:00:00Z", "merge_commit_sha": "mergesha0000000000", "base": {"ref": "release", "sha": "b"}, "head": {"sha": "h"}}]' \
  run_case "PR merged into another branch" <<<"$VALID"
check "exit" "$EXIT_CODE" 1
check "error" "$(output error-code)" PP_NO_MERGED_PR

PULLS='[{"number": 4, "merged_at": "2026-09-26T10:00:00Z", "merge_commit_sha": "someothersha", "base": {"ref": "main", "sha": "b"}, "head": {"sha": "h"}}]' \
  run_case "commit only contained in a PR, not merged by it" <<<"$VALID"
check "exit" "$EXIT_CODE" 1
check "error" "$(output error-code)" PP_NO_MERGED_PR

run_case "PR lookup fails" STUB_PULLS_FAIL=1 <<<"$VALID"
check "exit" "$EXIT_CODE" 1
check "error" "$(output error-code)" PP_PR_LOOKUP_FAILED
check "no PP call" "$(no_request)" none

PULLS='{"message": "Not Found"}' run_case "PR lookup returns an object" <<<"$VALID"
check "exit" "$EXIT_CODE" 1
check "error" "$(output error-code)" PP_PR_LOOKUP_FAILED
check "no PP call" "$(no_request)" none

PULLS="$MERGED" run_case "deploy mode rejects redeem false" PP_MODE=deploy PP_REDEEM=false <<<"$VALID"
check "exit" "$EXIT_CODE" 1
check "error" "$(output error-code)" PP_INVALID_CONFIG
check "no PP call" "$(no_request)" none

PULLS="$MERGED" run_case "deploy mode rejects fail-on-missing false" PP_FAIL_ON_MISSING=false <<<"$VALID"
check "exit" "$EXIT_CODE" 1
check "error" "$(output error-code)" PP_INVALID_CONFIG

run_case "deploy mode refuses pull_request events" PP_MODE=deploy PP_EVENT_NAME=pull_request PP_PR_NUMBER=12 PP_PR_HEAD_SHA=h <<<"$VALID"
check "exit" "$EXIT_CODE" 1
check "error" "$(output error-code)" PP_UNSUPPORTED_EVENT

run_case "deploy mode refuses tags" PP_REF=refs/tags/v1.0.0 <<<"$VALID"
check "exit" "$EXIT_CODE" 1
check "error" "$(output error-code)" PP_UNSUPPORTED_REF

run_case "auto mode refuses other events" PP_EVENT_NAME=schedule <<<"$VALID"
check "exit" "$EXIT_CODE" 1
check "error" "$(output error-code)" PP_UNSUPPORTED_EVENT

run_case "invalid mode" PP_MODE=yolo <<<"$VALID"
check "exit" "$EXIT_CODE" 1
check "error" "$(output error-code)" PP_INVALID_MODE

PULLS="$MERGED" run_case "no receipt for the merged PR" <<<'{"valid": false, "errorCode": "RECEIPT_NOT_FOUND", "requestId": "req_9"}'
check "exit" "$EXIT_CODE" 1
check "approved" "$(output approved)" false
check "approval-url" "$(output approval-url)" https://pp.test/pp/deploy-requests/req_9

PULLS="$MERGED" run_case "receipt already redeemed" <<<'{"valid": false, "errorCode": "RECEIPT_ALREADY_REDEEMED"}'
check "exit" "$EXIT_CODE" 1
check "error" "$(output error-code)" RECEIPT_ALREADY_REDEEMED

PULLS="$MERGED" run_case "receipt expired" <<<'{"valid": false, "errorCode": "RECEIPT_EXPIRED", "requestId": "req_3"}'
check "exit" "$EXIT_CODE" 1
check "error" "$(output error-code)" RECEIPT_EXPIRED

PULLS="$MERGED" run_case "expired, signer can renew" <<<'{"result": {"valid": false, "errorCode": "RECEIPT_EXPIRED"}, "reapproval": {"autoRenewEligible": true, "requestId": "req_3", "approvalUrl": "https://pp.test/approve/req_3"}}'
check "exit" "$EXIT_CODE" 1
check "error" "$(output error-code)" RECEIPT_EXPIRED
check "renew link" "$(output approval-url)" https://pp.test/approve/req_3

PULLS="$MERGED" run_case "expired, renewal refused" <<<'{"result": {"valid": false, "errorCode": "RECEIPT_EXPIRED"}, "reapproval": {"autoRenewEligible": false, "approvalUrl": "https://pp.test/approve/req_3", "reason": "This request is already merged"}}'
check "exit" "$EXIT_CODE" 1
check "no renew link" "$(output approval-url)" ""
check "reason shown" "$(grep -c 'already merged' "$CASE_DIR/stdout")" 1

PULLS="$MERGED" run_case "PP unavailable in production" STUB_STATUS=000 <<<''
check "exit" "$EXIT_CODE" 1
check "error" "$(output error-code)" PP_UNAVAILABLE

# --- pr mode is unchanged ---------------------------------------------------
PR_CTX=(PP_EVENT_NAME=pull_request PP_PR_NUMBER=12 PP_PR_HEAD_SHA=approvedhead12 PP_PR_BASE_SHA=base12)

run_case "pull_request gate" "${PR_CTX[@]}" <<<"$VALID"
check "exit" "$EXIT_CODE" 0
check "mode" "$(output mode)" pr
check "scope" "$(request .scope)" '{"repo":"acme/web","prNumber":12,"headSha":"approvedhead12","env":"production","capability":"deploy:production"}'
check "redeem defaults off" "$(request .redeem)" false
check "no commit lookup" "$(grep -c '/pulls' "$CASE_DIR/gh.log")" 0

run_case "pull_request gate with redeem true" "${PR_CTX[@]}" PP_REDEEM=true <<<"$VALID"
check "redeem" "$(request .redeem)" true

run_case "draft PR skipped" "${PR_CTX[@]}" STUB_IS_DRAFT=true <<<"$VALID"
check "exit" "$EXIT_CODE" 0
check "decision" "$(output decision)" DRAFT_SKIPPED
check "no PP call" "$(no_request)" none

run_case "pr mode without a PR" PP_MODE=pr <<<"$VALID"
check "exit" "$EXIT_CODE" 1
check "error" "$(output error-code)" PP_NO_PR_CONTEXT
check "no PP call" "$(no_request)" none

run_case "pr gate missing receipt, fail-on-missing false" "${PR_CTX[@]}" PP_FAIL_ON_MISSING=false <<<'{"valid": false, "errorCode": "RECEIPT_NOT_FOUND"}'
check "exit" "$EXIT_CODE" 0

# Carry-forward receipts require explicit opt-in in either mode.
CARRIED='{"valid":true,"receiptId":"rcpt_1","decision":"APPROVED","carriedForward":true}'
run_case "carried-forward PR receipt rejected by default" "${PR_CTX[@]}" <<<"$CARRIED"
check "exit" "$EXIT_CODE" 1
check "approved" "$(output approved)" false
check "error" "$(output error-code)" PP_CARRY_FORWARD_DISABLED

run_case "carried-forward PR receipt explicitly allowed" "${PR_CTX[@]}" PP_ALLOW_CARRY_FORWARD=TrUe <<<"$CARRIED"
check "exit" "$EXIT_CODE" 0
check "approved" "$(output approved)" true

run_case "invalid carry-forward opt-in stays closed" "${PR_CTX[@]}" PP_ALLOW_CARRY_FORWARD=yes <<<"$CARRIED"
check "exit" "$EXIT_CODE" 1
check "approved" "$(output approved)" false

PULLS="$MERGED" run_case "carried-forward deploy receipt rejected by default" <<<"$CARRIED"
check "exit" "$EXIT_CODE" 1
check "error" "$(output error-code)" PP_CARRY_FORWARD_DISABLED
check "redeem" "$(request .redeem)" true

PULLS="$MERGED" run_case "carried-forward deploy receipt explicitly allowed" PP_ALLOW_CARRY_FORWARD=true <<<"$CARRIED"
check "exit" "$EXIT_CODE" 0
check "approved" "$(output approved)" true
check "redeem" "$(request .redeem)" true

# --- the PR title rides along, so PP can show it without reading GitHub ------
utf16() { jq -r '[.prTitle | explode[] | if . > 65535 then 2 else 1 end] | add' "$CASE_DIR/request.json"; }

run_case "PR title is sent as JSON, quotes and newlines intact" "${PR_CTX[@]}" "PP_PR_TITLE=$(printf 'Fix "auth" redirect\nloop $(id)')" <<<"$VALID"
check "exit" "$EXIT_CODE" 0
check "title" "$(request .prTitle)" '"Fix \"auth\" redirect\nloop $(id)"'
check "scope unchanged" "$(request .scope)" '{"repo":"acme/web","prNumber":12,"headSha":"approvedhead12","env":"production","capability":"deploy:production"}'

run_case "empty PR title is left out" "${PR_CTX[@]}" PP_PR_TITLE= <<<"$VALID"
check "no key" "$(request 'has("prTitle")')" false

run_case "long PR title is cut to 300" "${PR_CTX[@]}" "PP_PR_TITLE=$(printf 'x%.0s' $(seq 1 400))" <<<"$VALID"
check "length" "$(request '.prTitle | length')" 300

run_case "emoji PR title stays within 300 UTF-16 units" "${PR_CTX[@]}" "PP_PR_TITLE=$(for i in $(seq 1 200); do printf '\360\237\232\200'; done)" <<<"$VALID"
check "code points" "$(request '.prTitle | length')" 150
check "utf-16 units" "$(utf16)" 300

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
