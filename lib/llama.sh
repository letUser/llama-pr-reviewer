# llama-server interaction: tokenize preflight, SSE stream, parse output.
# Sourced by bin/review-pr. Requires LLAMA_URL, LLAMA_MODEL, CTX_SIZE,
# CTX_SAFETY_MARGIN, MAX_TOKENS, LOCK_DIR in scope.

# shellcheck shell=bash

cleanup_vram() {
  curl -s -X POST "$LLAMA_URL/slots/0?action=erase" >/dev/null 2>&1 \
    && echo "Cleared llama-server slot 0." \
    || echo "WARNING: failed to erase llama-server slot 0."
}

# Count prompt tokens via /tokenize. Falls back to char/4 estimate.
# Sets PROMPT_TOKENS global.
preflight_token_count() {
  local sys="$1" user="$2"
  local combined_file tok_json_file tok_resp
  # Use temp files to avoid ARG_MAX limits on big PRs (jq --arg and curl -d
  # both pass via argv, which blows up past ~128 KB).
  combined_file="$LOCK_DIR/preflight-content.txt"
  tok_json_file="$LOCK_DIR/preflight-req.json"
  printf '%s\n%s' "$sys" "$user" > "$combined_file"
  jq -n --rawfile c "$combined_file" '{content: $c}' > "$tok_json_file"
  tok_resp="$(curl -s -X POST "$LLAMA_URL/tokenize" \
    -H 'content-type: application/json' \
    --data-binary "@$tok_json_file")"
  PROMPT_TOKENS="$(jq -r '.tokens | length' <<<"$tok_resp" 2>/dev/null || echo "")"

  if [[ -z "$PROMPT_TOKENS" || "$PROMPT_TOKENS" == "null" ]]; then
    PROMPT_TOKENS=$(( (${#sys} + ${#user}) / 4 ))
    echo "warn: /tokenize unavailable, estimated prompt_tokens≈$PROMPT_TOKENS" >&2
  fi
}

# Enforce ctx budget. Exits 5 if exceeded.
enforce_ctx_budget() {
  local budget_limit needed
  budget_limit=$(( CTX_SIZE - CTX_SAFETY_MARGIN ))
  needed=$(( PROMPT_TOKENS + MAX_TOKENS ))
  echo "tokens: prompt=$PROMPT_TOKENS max_output=$MAX_TOKENS ctx=$CTX_SIZE (margin=$CTX_SAFETY_MARGIN)"

  if (( needed > budget_limit )); then
    echo "ERROR: prompt($PROMPT_TOKENS) + MAX_TOKENS($MAX_TOKENS) = $needed exceeds ctx budget $budget_limit." >&2
    echo "Options: shrink diff (HUNK_CONTEXT_LINES, MAX_SYMBOLS), lower MAX_TOKENS, or raise CTX_SIZE/server -c." >&2
    exit 5
  fi
}

# Stream SSE, write content + reasoning to files. Sets:
#   REVIEW_MD, REASONING, USAGE, FINISH_REASON globals.
# Args: $1=system_prompt, $2=user_prompt
stream_chat_completion() {
  local sys="$1" user="$2"
  local stream_file reasoning_file content_file sys_file user_file req_file

  stream_file="$LOCK_DIR/last-stream.sse"
  reasoning_file="$LOCK_DIR/last-reasoning.txt"
  content_file="$LOCK_DIR/last-content.txt"
  sys_file="$LOCK_DIR/req-sys.txt"
  user_file="$LOCK_DIR/req-user.txt"
  req_file="$LOCK_DIR/req-body.json"
  : > "$stream_file"
  : > "$reasoning_file"
  : > "$content_file"

  # Write sys+user to files to dodge ARG_MAX on large prompts.
  printf '%s' "$sys" > "$sys_file"
  printf '%s' "$user" > "$user_file"
  jq -n \
    --arg model "$LLAMA_MODEL" \
    --rawfile sys "$sys_file" \
    --rawfile user "$user_file" \
    --argjson max_tokens "$MAX_TOKENS" \
    '{
      model: $model,
      messages: [
        { role: "system", content: $sys },
        { role: "user", content: $user }
      ],
      temperature: 0.2,
      top_p: 0.9,
      max_tokens: $max_tokens,
      stream: true,
      stream_options: { include_usage: true }
    }' > "$req_file"

  curl -sN -X POST "$LLAMA_URL/v1/chat/completions" \
    -H 'content-type: application/json' \
    --data-binary "@$req_file" 2>/dev/null \
    | tee "$stream_file" \
    | while IFS= read -r line; do
        [[ "$line" == "data: "* ]] || continue
        local payload="${line#data: }"
        [[ "$payload" == "[DONE]" ]] && continue
        jq -rj '.choices[0].delta.content // ""' <<<"$payload" 2>/dev/null >> "$content_file"
        jq -rj '.choices[0].delta.reasoning_content // ""' <<<"$payload" 2>/dev/null >> "$reasoning_file"
      done

  REVIEW_MD="$(cat "$content_file")"
  # Strip <think>...</think> blocks. Also handle stray closing tags emitted
  # without an opening (small reasoning models sometimes leak CoT into the
  # content channel and only emit the closing tag): drop everything up to
  # and including the first </think>.
  REVIEW_MD="$(printf '%s' "$REVIEW_MD" | perl -0777 -pe 's|<think>.*?</think>\s*||gs; s|\A.*?</think>\s*||s')"
  # Fallback: if a Markdown review header exists somewhere, trim any
  # remaining preamble before it.
  REVIEW_MD="$(printf '%s' "$REVIEW_MD" | perl -0777 -pe 's|\A(?:(?!^# PR #).)*?(?=^# PR #)||ms')"
  # Normalize conclusion emoji: small reasoning models drop the U+FE0F variation
  # selector on ⚠️, producing a bare ⚠. ✅ ❌ ❓ are single codepoints — fine.
  REVIEW_MD="$(printf '%s' "$REVIEW_MD" | perl -CSD -0777 -pe 's/\x{26A0}(?!\x{FE0F})/\x{26A0}\x{FE0F}/g')"
  REASONING="$(cat "$reasoning_file")"
  USAGE="$(grep '^data: ' "$stream_file" | sed 's/^data: //' | jq -rs 'map(select(.usage)) | last | .usage // {} | "prompt=\(.prompt_tokens // "?") completion=\(.completion_tokens // "?") total=\(.total_tokens // "?")"' 2>/dev/null || true)"
  [[ -n "$USAGE" ]] && echo "usage: $USAGE"
  FINISH_REASON="$(grep '^data: ' "$stream_file" | sed 's/^data: //' | jq -rs 'map(.choices[0].finish_reason // empty) | last // ""' 2>/dev/null || true)"
}

# Validate model output has the Conclusion line. Exits 4 if not.
validate_review_output() {
  if [[ -z "$REVIEW_MD" || ! "$REVIEW_MD" =~ "Conclusion:" ]]; then
    echo "ERROR: model output missing Conclusion line. finish_reason=$FINISH_REASON, content_len=${#REVIEW_MD}, reasoning_len=${#REASONING}" >&2
    if [[ "$FINISH_REASON" == "length" && -z "$REVIEW_MD" && -n "$REASONING" ]]; then
      echo "Hint: thinking budget exhausted before answer. Raise MAX_TOKENS (current=$MAX_TOKENS) or shrink prompt." >&2
    fi
    echo "---response head---" >&2
    printf '%s' "$REVIEW_MD" | head -c 2000 >&2
    echo >&2
    exit 4
  fi
}
