# Config + env loading for review-pr.
# Sourced by bin/review-pr. Reads $DATA_DIR/.env if present, exports budgets,
# noise pathspecs, and resolves a GNU-compatible date command.

# shellcheck shell=bash

load_env_file() {
  local cfg="$1"
  if [[ -f "$cfg" ]]; then
    # shellcheck source=/dev/null
    source "$cfg"
  fi
}

resolve_date_cmd() {
  if date -d @0 +%s >/dev/null 2>&1; then
    DATE_CMD=date
  elif command -v gdate >/dev/null 2>&1 && gdate -d @0 +%s >/dev/null 2>&1; then
    DATE_CMD=gdate
  else
    echo "ERROR: GNU date required. On macOS: brew install coreutils." >&2
    exit 1
  fi
}

# Budget — tuned for ~24k useful tokens
init_budgets() {
  MAX_DIFF_BYTES="${MAX_DIFF_BYTES:-240000}"
  OVERSIZE_DIFF_BYTES="${OVERSIZE_DIFF_BYTES:-360000}" # Hard cap: skip model + request human review.
  MAX_PR_BODY_BYTES="${MAX_PR_BODY_BYTES:-1500}"
  HUNK_CONTEXT_LINES="${HUNK_CONTEXT_LINES:-3}" # Default 3 (git/gh standard); avoid >5 — bloats tokens.
  MAX_SYMBOLS="${MAX_SYMBOLS:-15}"
  MAX_CALLERS_PER_SYMBOL="${MAX_CALLERS_PER_SYMBOL:-3}"
  MAX_COMMENT_BODY="${MAX_COMMENT_BODY:-200}"

  # thinking mode eats tokens before answer. Give big budget.
  MAX_TOKENS="${MAX_TOKENS:-24576}"

  # llama-server context size. prompt + MAX_TOKENS must fit.
  CTX_SIZE="${CTX_SIZE:-131072}"
  CTX_SAFETY_MARGIN="${CTX_SAFETY_MARGIN:-2048}"

  MAX_TITLE_LEN="${MAX_TITLE_LEN:-60}"

  # Tag a verifier bot at end of review when findings need second-pair-of-eyes.
  # Mention is only appended for NEEDS CHANGES / NEEDS CLARIFICATION conclusions.
  VERIFY_BOT="${VERIFY_BOT:-}"
  BOT_OWNER="${BOT_OWNER:-}" # GitHub login @-mentioned on oversize-diff skip.

  # Comma-separated bot logins to exclude when fetching prior comments/reviews.
  SKIP_PRIOR_AUTHORS="${SKIP_PRIOR_AUTHORS:-}"
  if [[ -n "$VERIFY_BOT" ]]; then
    SKIP_PRIOR_AUTHORS="${SKIP_PRIOR_AUTHORS:+$SKIP_PRIOR_AUTHORS,}$VERIFY_BOT,${VERIFY_BOT}[bot]"
  fi

  SKIP_AUTHORS="${SKIP_AUTHORS:-}"
}

# Pathspecs excluded from the diff sent to the model. Triage gate already
# auto-skips all-noise PRs; these patterns drop noise hunks from mixed PRs so
# the model never reviews lockfiles, binaries, minified bundles, etc.
NOISE_PATHSPECS=(
  ':(exclude,glob)**/*.lock'
  ':(exclude,glob)**/*.lockb'
  ':(exclude,glob)**/package-lock.json'
  ':(exclude,glob)**/yarn.lock'
  ':(exclude,glob)**/pnpm-lock.yaml'
  ':(exclude,glob)**/Cargo.lock'
  ':(exclude,glob)**/Gemfile.lock'
  ':(exclude,glob)**/poetry.lock'
  ':(exclude,glob)**/Pipfile.lock'
  ':(exclude,glob)**/composer.lock'
  ':(exclude,glob)**/*.min.js'
  ':(exclude,glob)**/*.min.css'
  ':(exclude,glob)**/*.map'
  ':(exclude,glob)**/*.svg'
  ':(exclude,glob)**/*.png'
  ':(exclude,glob)**/*.jpg'
  ':(exclude,glob)**/*.jpeg'
  ':(exclude,glob)**/*.gif'
  ':(exclude,glob)**/*.ico'
  ':(exclude,glob)**/*.pdf'
  ':(exclude,glob)**/*.bin'
  ':(exclude,glob)**/*.woff'
  ':(exclude,glob)**/*.woff2'
  ':(exclude,glob)**/*.ttf'
  ':(exclude,glob)**/*.eot'
  ':(exclude,glob)**/*.snap'
  ':(exclude,glob)**/*.snapshot'
  ':(exclude,glob)**/CHANGELOG.md'
  ':(exclude,glob)**/CHANGELOG'
)
