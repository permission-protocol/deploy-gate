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
  if [ "$1" = "-d" ]; then printf '%s' "$2" > "$STUB_DIR/request.json"; printf '%s' "$2" | jq -c . >> "$STUB_DIR/requests.jsonl"; fi
  shift
done
if [ -n "${STUB_SEQUENCE:-}" ]; then
  n=$(( $(cat "$STUB_DIR/call-count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/call-count"
  reply=$(printf '%s' "$STUB_SEQUENCE" | jq -c --argjson i "$((n - 1))" '.[$i] // .[-1]')
  printf '%s' "$reply" | jq -r '.body | if type == "string" then . else tojson end'
  printf '\n%s' "$(printf '%s' "$reply" | jq -r '.http')"
  exit "$(printf '%s' "$reply" | jq -r '.exit // 0')"
fi
cat "$STUB_DIR/response.json"
printf '\n%s' "${STUB_STATUS:-200}"
STUB
chmod +x "$WORK/bin/gh" "$WORK/bin/curl"
cat > "$WORK/bin/date" <<'STUB'
#!/usr/bin/env bash
cat "$STUB_DIR/clock" 2>/dev/null || echo 0
STUB
cat > "$WORK/bin/sleep" <<'STUB'
#!/usr/bin/env bash
echo $(( $(cat "$STUB_DIR/clock" 2>/dev/null || echo 0) + ${STUB_TICK:-15} )) > "$STUB_DIR/clock"
STUB
chmod +x "$WORK/bin/date" "$WORK/bin/sleep"

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
    export PP_REDEEM= PP_FAIL_ON_MISSING=true PP_PROTECTED_PATHS='^(deploy/|\.github/workflows/)'
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

PULLS="$MERGED" run_case "expired, signer can renew, opt-out wait" PP_WAIT_FOR_APPROVAL=false <<<'{"result": {"valid": false, "errorCode": "RECEIPT_EXPIRED"}, "reapproval": {"autoRenewEligible": true, "requestId": "req_3", "approvalUrl": "https://pp.test/approve/req_3"}}'
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

# --- transient recovery never retries a redemption --------------------------
sequence_redeems() { jq -sc 'map(.redeem)' "$CASE_DIR/requests.jsonl"; }
for code in INTERNAL_ERROR RATE_LIMITED POLICY_UNAVAILABLE; do
  case "$code" in INTERNAL_ERROR) status=500 ;; RATE_LIMITED) status=429 ;; *) status=503 ;; esac
  sequence=$(jq -cn --arg code "$code" --argjson status "$status" --argjson valid "$VALID" '[{http:$status,body:{error:{code:$code}}},{http:200,body:$valid},{http:200,body:$valid}]')
  PULLS="$MERGED" run_case "recovers from $code" STUB_SEQUENCE="$sequence" <<<''
  check "exit" "$EXIT_CODE" 0
  check "one redemption" "$(sequence_redeems)" '[false,false,true]'
  check "exact artifact preserved" "$(jq -sc 'map(.scope) | unique | length' "$CASE_DIR/requests.jsonl")" 1
done

for status in 429 500 502 503 504; do
  sequence=$(jq -cn --argjson status "$status" --argjson valid "$VALID" '[{http:$status,body:"<html>Unavailable</html>"},{http:200,body:$valid},{http:200,body:$valid}]')
  PULLS="$MERGED" run_case "gateway $status recovers" STUB_SEQUENCE="$sequence" <<<''
  check "exit" "$EXIT_CODE" 0
  check "one redemption" "$(sequence_redeems)" '[false,false,true]'
done

sequence=$(jq -cn --argjson valid "$VALID" '[{http:200,body:$valid,exit:18},{http:200,body:$valid},{http:200,body:$valid}]')
PULLS="$MERGED" run_case "partial success is discarded" STUB_SEQUENCE="$sequence" <<<''
check "exit" "$EXIT_CODE" 0
check "one redemption" "$(sequence_redeems)" '[false,false,true]'

for code in RECEIPT_DENIED RECEIPT_REVOKED SIGNATURE_INVALID TENANT_KEY_MISSING POLICY_CHANGED; do
  sequence=$(jq -cn --arg code "$code" --argjson valid "$VALID" '[{http:503,body:{error:{code:$code}}},{http:200,body:$valid}]')
  PULLS="$MERGED" run_case "never retries refusal $code" STUB_SEQUENCE="$sequence" <<<''
  check "exit" "$EXIT_CODE" 1
  check "no redemption" "$(sequence_redeems)" '[false]'
done

sequence=$(jq -cn --argjson valid "$VALID" '[{http:200,body:$valid},{http:500,body:{error:{code:"INTERNAL_ERROR"}}},{http:200,body:$valid}]')
PULLS="$MERGED" run_case "ambiguous redemption is never replayed" STUB_SEQUENCE="$sequence" <<<''
check "exit" "$EXIT_CODE" 1
check "uncertain redemption" "$(output error-code)" PP_REDEMPTION_UNCERTAIN
check "one redemption" "$(sequence_redeems)" '[false,true]'

sequence='[{"http":500,"body":{"error":{"code":"INTERNAL_ERROR"}}}]'
PULLS="$MERGED" run_case "outage ends closed at deadline" STUB_SEQUENCE="$sequence" STUB_TICK=1800 <<<''
check "exit" "$EXIT_CODE" 1
check "no redemption" "$(sequence_redeems)" '[false,false]'
check "recovery message" "$(grep -c 'Nothing was redeemed or deployed' "$CASE_DIR/stdout")" 1

sequence=$(jq -cn --argjson valid "$VALID" '[{http:410,body:{result:{valid:false,errorCode:"RECEIPT_EXPIRED"},reapproval:{autoRenewEligible:true,approvalUrl:"https://pp.test/approve/req_3"}}},{http:200,body:$valid},{http:200,body:$valid}]')
PULLS="$MERGED" run_case "waits for human renewal and resumes" STUB_SEQUENCE="$sequence" <<<''
check "exit" "$EXIT_CODE" 0
check "one redemption" "$(sequence_redeems)" '[false,false,true]'
check "renewal link" "$(grep -c 'https://pp.test/approve/req_3/renew' "$CASE_DIR/stdout")" 1

for policy in GITHUB_RATE_LIMITED GITHUB_TIMEOUT GITHUB_NETWORK_ERROR GITHUB_TOKEN_SERVICE_UNAVAILABLE; do
  sequence=$(jq -cn --arg policy "$policy" --argjson valid "$VALID" '[{http:409,body:{errorCode:"POLICY_AUTHORIZATION_REQUIRED",policyRead:{code:$policy}}},{http:200,body:$valid},{http:200,body:$valid}]')
  PULLS="$MERGED" run_case "recovers policy read $policy" STUB_SEQUENCE="$sequence" <<<''
  check "exit" "$EXIT_CODE" 0
  check "one redemption" "$(sequence_redeems)" '[false,false,true]'
done

for status in 401 403; do
  sequence=$(jq -cn --argjson status "$status" --argjson valid "$VALID" '[{http:$status,body:{error:{code:"INTERNAL_ERROR"}}},{http:200,body:$valid}]')
  PULLS="$MERGED" run_case "authentication refusal $status is terminal" STUB_SEQUENCE="$sequence" <<<''
  check "exit" "$EXIT_CODE" 1
  check "no redemption" "$(sequence_redeems)" '[false]'
done

sequence=$(jq -cn --argjson valid "$VALID" '[{http:500,body:{error:{code:"INTERNAL_ERROR"}}},{http:200,body:$valid}]')
run_case "PR read recovers without redemption" "${PR_CTX[@]}" STUB_SEQUENCE="$sequence" <<<''
check "exit" "$EXIT_CODE" 0
check "reads only" "$(sequence_redeems)" '[false,false]'

sequence=$(jq -cn --argjson valid "$VALID" '[{http:200,body:$valid},{http:200,body:$valid,exit:18},{http:200,body:$valid}]')
PULLS="$MERGED" run_case "truncated redemption success is never accepted or replayed" STUB_SEQUENCE="$sequence" <<<''
check "exit" "$EXIT_CODE" 1
check "uncertain redemption" "$(output error-code)" PP_REDEMPTION_UNCERTAIN
check "one redemption" "$(sequence_redeems)" '[false,true]'

sequence=$(jq -cn --argjson valid "$VALID" '[{http:410,body:{result:{valid:false,errorCode:"RECEIPT_EXPIRED"},reapproval:{autoRenewEligible:false,reason:"Receipt has not expired"}}},{http:200,body:$valid},{http:200,body:$valid}]')
PULLS="$MERGED" run_case "renewal concurrent with read recovers" STUB_SEQUENCE="$sequence" <<<''
check "exit" "$EXIT_CODE" 0
check "one redemption" "$(sequence_redeems)" '[false,false,true]'

sequence='[{"http":404,"body":{"valid":false,"errorCode":"RECEIPT_NOT_FOUND","approvalUrl":"https://pp.test/approve/req_3"}}]'
PULLS="$MERGED" run_case "missing human approval never becomes a non-production fail-open" STUB_SEQUENCE="$sequence" STUB_TICK=1800 PP_ENVIRONMENT=staging PP_FAIL_MODE=open <<<''
check "exit" "$EXIT_CODE" 1
check "approval timed out" "$(output error-code)" PP_APPROVAL_TIMEOUT
check "not approved" "$(output approved)" false
check "no redemption" "$(sequence_redeems)" '[false,false]'

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
