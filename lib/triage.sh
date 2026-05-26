# Triage gate: classify diffs that don't need model review.
# Sourced by bin/review-pr.

# shellcheck shell=bash

is_noise_path() {
  case "$1" in
    *.lock|*.lockb|*package-lock.json|*yarn.lock|*pnpm-lock.yaml|*Cargo.lock|*Gemfile.lock|*poetry.lock|*Pipfile.lock|*composer.lock) return 0 ;;
    *.min.js|*.min.css|*.map) return 0 ;;
    *.svg|*.png|*.jpg|*.jpeg|*.gif|*.ico|*.pdf|*.bin|*.woff|*.woff2|*.ttf|*.eot) return 0 ;;
    *.snap|*.snapshot) return 0 ;;
    *)
      case "$(basename "$1")" in
        CHANGELOG.md|CHANGELOG) return 0 ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

# Dep manifests: meaningful files that, when changed alongside only lockfiles,
# still represent a dep-only PR (no application logic).
is_dep_manifest() {
  case "$(basename "$1")" in
    package.json|composer.json|Gemfile|requirements.txt|Pipfile|go.mod|go.sum) return 0 ;;
    *) return 1 ;;
  esac
}

# Sets TRIAGE_SKIP_REASON to non-empty string when diff should skip model.
# Inputs: $1=diff_raw_full, $2=changed_files_all, $3=diff_base, $4=head_sha
classify_triage() {
  local diff_raw_full="$1"
  local changed_files_all="$2"
  local diff_base="$3"
  local head_sha="$4"

  TRIAGE_SKIP_REASON=""
  if [[ -z "$diff_raw_full" ]]; then
    TRIAGE_SKIP_REASON="empty diff"
    return
  fi
  if [[ -z "$changed_files_all" ]]; then
    TRIAGE_SKIP_REASON="no changed files"
    return
  fi

  local all_skip=1 has_dep_manifest=0 f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if is_dep_manifest "$f"; then
      has_dep_manifest=1
      continue
    fi
    if ! is_noise_path "$f"; then
      all_skip=0
      break
    fi
  done <<<"$changed_files_all"

  if (( all_skip == 1 )); then
    if (( has_dep_manifest == 1 )); then
      TRIAGE_SKIP_REASON="dependency-only update"
    else
      TRIAGE_SKIP_REASON="lockfile/generated/binary-only diff"
    fi
    return
  fi

  # Whitespace-only check on the actual code changes. INCR_PATHS (global, set by
  # the orchestrator) narrows this to the PR's own files in incremental mode;
  # empty otherwise, so all paths are considered.
  local ws_diff
  ws_diff="$(git diff -w "$diff_base..$head_sha" -- "${INCR_PATHS[@]}" 2>/dev/null || true)"
  if [[ -z "$ws_diff" ]]; then
    TRIAGE_SKIP_REASON="whitespace-only diff"
  fi
}

# Post a skip approval to GitHub and exit 0.
# $1=reason, $2=pr_number, $3=full_repo, $4=pr_title
triage_skip_approve() {
  local reason="$1" pr_number="$2" full_repo="$3" pr_title="$4"
  cat > pr-review.md <<EOF
# PR #$pr_number Review — $pr_title

**Auto-skipped:** $reason. No model review needed.

**Conclusion:** APPROVED ✅
EOF
  gh pr comment "$pr_number" --repo "$full_repo" --body-file pr-review.md
  gh pr review "$pr_number" --repo "$full_repo" --approve \
    --body "Auto-approved: $reason." \
    || echo "WARN: gh pr review --approve failed."
  rm -f pr-review.md
}

# Post a "needs human review" comment (no approve) and exit 0.
# Mentions $BOT_OWNER to trigger GitHub notification.
# $1=reason, $2=pr_number, $3=full_repo, $4=pr_title
triage_skip_human_review() {
  local reason="$1" pr_number="$2" full_repo="$3" pr_title="$4"
  local mention=""
  [[ -n "$BOT_OWNER" ]] && mention=" @${BOT_OWNER}"
  cat > pr-review.md <<EOF
# PR #$pr_number Review — $pr_title

**Skipped:** $reason.

Exceeds size limit for automated review. Needs human review.${mention}

**Conclusion:** NEEDS_REVIEW
EOF
  gh pr comment "$pr_number" --repo "$full_repo" --body-file pr-review.md
  rm -f pr-review.md
}
