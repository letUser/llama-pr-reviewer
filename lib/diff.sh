# Diff processing: strip noise, annotate lines, extract changed symbols,
# find caller hits. Sourced by bin/review-pr.

# shellcheck shell=bash

# Build short aliases for changed files. Long filenames get fragmented by the
# tokenizer in small reasoning models (digit runs in migration timestamps,
# compound CamelCase paths), causing the CoT to spiral on filename
# reconstruction. Aliasing to F1/F2/... gives the model stable single-token
# references; we restore real paths in REVIEW_MD post-stream.
#
# Sets globals:
#   ALIAS_LIST  — formatted text for the prompt ("F1 = path\nF2 = path\n...")
#   ALIAS_MAP   — tab-separated alias\tpath, newline-separated
build_alias_map() {
  local files="$1" idx=1 path
  ALIAS_LIST=""
  ALIAS_MAP=""
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    ALIAS_LIST+="F${idx} = ${path}
"
    ALIAS_MAP+="F${idx}	${path}
"
    ((idx++))
  done <<<"$files"
}

# Substitute real paths with their aliases in arbitrary text.
apply_aliases() {
  local text="$1" alias path
  while IFS=$'\t' read -r alias path; do
    [[ -z "$alias" ]] && continue
    text="$(printf '%s' "$text" | ALIAS="$alias" PATHV="$path" perl -pe '
      BEGIN { $a = $ENV{ALIAS}; $p = quotemeta($ENV{PATHV}); }
      s/$p/$a/g;
    ')"
  done <<<"$ALIAS_MAP"
  printf '%s' "$text"
}

# Restore real paths from aliases in REVIEW_MD. Uses word boundaries so F1
# doesn't match inside F10. Path is inserted via env var to avoid perl
# interpolation pitfalls with slashes/dots.
restore_aliases() {
  local text="$1" alias path
  while IFS=$'\t' read -r alias path; do
    [[ -z "$alias" ]] && continue
    text="$(printf '%s' "$text" | ALIAS="$alias" PATHV="$path" perl -pe '
      BEGIN { $a = $ENV{ALIAS}; $p = $ENV{PATHV}; }
      s/\b\Q$a\E\b/$p/g;
    ')"
  done <<<"$ALIAS_MAP"
  printf '%s' "$text"
}

strip_diff_noise() {
  sed -E \
    -e '/^index [0-9a-f]+\.\.[0-9a-f]+/d' \
    -e '/^similarity index /d' \
    -e '/^dissimilarity index /d' \
    -e '/^rename from /d' \
    -e '/^rename to /d' \
    -e '/^new file mode /d' \
    -e '/^deleted file mode /d' \
    -e '/^old mode /d' \
    -e '/^new mode /d' \
    -e '/^Binary files .* differ$/d'
}

# Pull added identifiers from `+` lines matching common decl patterns.
# Reads $DIFF on stdin via caller; uses $MAX_SYMBOLS.
extract_symbols() {
  local diff_text="$1"
  printf '%s\n' "$diff_text" \
    | grep -E '^\+[^+]' \
    | sed -E 's/^\+//' \
    | grep -oE '(function|def|class|interface|type|fn|func|struct|enum|trait|impl|module|namespace|const|let|var|public|private|protected|static)[[:space:]]+[A-Za-z_][A-Za-z0-9_]+' \
    | sed -E 's/^[A-Za-z]+[[:space:]]+//' \
    | awk 'length($0) >= 4' \
    | grep -Ev '^(if|else|for|while|return|true|false|null|None|self|this|args|kwargs|data|item|value|test|init|main|String|Number|Boolean|Object|Array)$' \
    | sort -u \
    | head -n "$MAX_SYMBOLS"
}

# Build the caller-hits markdown section for the changed symbols.
# $1=symbols (newline-separated), $2=changed_files (newline-separated)
build_callers_section() {
  local symbols="$1" changed_files="$2"
  [[ -z "$symbols" ]] && return 0

  local out="## Caller hits for changed symbols
"
  local sym hits
  while IFS= read -r sym; do
    [[ -z "$sym" ]] && continue
    hits="$(git grep -n --fixed-strings "$sym" -- \
              ':!*test*' ':!*spec*' ':!*__tests__*' ':!*node_modules*' ':!*dist*' ':!*build*' \
              2>/dev/null \
              | awk -F: -v changed="$changed_files" '
                  BEGIN { n=split(changed,a,"\n"); for(i=1;i<=n;i++) if(a[i]!="") c[a[i]]=1 }
                  !($1 in c)' \
              | head -n "$MAX_CALLERS_PER_SYMBOL" || true)"
    if [[ -n "$hits" ]]; then
      out+="
### \`$sym\`
\`\`\`
$hits
\`\`\`"
    fi
  done <<<"$symbols"
  printf '%s' "$out"
}
