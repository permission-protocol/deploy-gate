#!/usr/bin/env bash
# Read the outcome of this exact attempt. Never submit another redemption.
pp_reconcile_redemption() {
  local deadline=$(( $(date +%s) + 75 )) read_body response body status failed
  [[ "${PP_REDEEM:-}" == true && "${PP_REDEMPTION_ATTEMPT_HASH:-}" =~ ^[a-f0-9]{64}$ ]] || return 1
  read_body=$(printf '%s' "$REQUEST_BODY" | jq -c '.redeem = false | .reconcileRedemption = true')
  while :; do
    failed=0
    response=$(curl -sS --max-time 15 -w '\n%{http_code}' -X POST "${PP_BASE_URL}/api/v1/receipts/verify" \
      -H 'Content-Type: application/json' -H "X-PP-API-Key: ${PP_API_KEY}" \
      -H 'X-PP-Request-Source: github-actions' -H "X-GitHub-Run-Id: ${PP_RUN_ID}" \
      "${CHECK_RUN_HEADERS[@]}" -d "$read_body" 2>/dev/null) || failed=$?
    body=$(printf '%s\n' "$response" | sed '$d')
    status=$(printf '%s\n' "$response" | tail -n1)
    if [[ "$failed" == 0 && "$status" == 200 ]] && printf '%s' "$body" | jq -e \
      --arg hash "$PP_REDEMPTION_ATTEMPT_HASH" --arg run "$PP_RUN_ID" --arg id "$(printf '%s' "$REQUEST_BODY" | jq -r '.receiptId // empty')" '
        .success == true and .result.valid == true and .result.receipt.decision == "APPROVED" and
        (.result.receipt.demo == false) and (.result.receipt.redeemedAt | type == "string" and length > 0) and
        ($id | length > 0) and .result.receipt.id == $id and
        .result.receipt.redeemAttemptHash == $hash and .result.receipt.redeemedRunId == $run' >/dev/null 2>&1; then
      HTTP_RESPONSE="$response"
      set_output redemption_recovered true
      echo 'The exact workflow attempt already consumed this still-valid authorization. Recovered by a read; no redemption was replayed.'
      return 0
    fi
    # These are conclusive refusals, not transport failures. A used receipt
    # under another attempt cannot authorize this one, even for the same SHA.
    if [[ "$failed" == 0 ]] && printf '%s' "$body" | jq -e '
      [.errorCode, .result.errorCode, .error.code] | any(. == "RECEIPT_REVOKED" or . == "RECEIPT_EXPIRED" or
        . == "RECEIPT_DENIED" or . == "SIGNATURE_INVALID" or . == "SCOPE_MISMATCH")' >/dev/null 2>&1; then return 1; fi
    if [[ "$failed" == 0 && "$status" == 200 ]] && printf '%s' "$body" | jq -e \
      --arg hash "$PP_REDEMPTION_ATTEMPT_HASH" '.result.receipt.redeemedAt != null and .result.receipt.redeemAttemptHash != $hash' >/dev/null 2>&1; then return 1; fi
    if (( $(date +%s) + 15 >= deadline )); then return 1; fi
    sleep 15
  done
}
