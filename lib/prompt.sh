# Prompt builder: assembles system + user prompts and review templates.
# Sourced by bin/review-pr. Sets SYSTEM_PROMPT and USER_PROMPT globals.

# shellcheck shell=bash

SYSTEM_PROMPT_TEXT="Senior PR reviewer. No praise.

Review only '+' lines. Assume unchanged code compiles. Filtered files (lockfiles, binaries) are out of scope — ignore PR title/description references to them.

One pass through the diff sets your verdict. Do not re-walk fields, re-quote constraints, or re-verify the template. Never flag a syntax-level concern (missing punctuation, broken brackets, identifier mismatch, trailing commas, whitespace, missing \`this.\`) found on a re-read — that is tokenizer noise, not a real bug. Trust your first read. After thinking, always emit the full review markdown.

Findings: cite file alias (F1, F2, …) from Changed files. No line numbers. Describe location by symbol/function. If unsure, omit.
- BLOCKER: concrete harm (exploit, data loss, broken happy path)
- MAJOR: bug with named failure mode
- MINOR: real style nit
- One finding per issue. Don't review unchanged code.

Empty sections: '**Findings:** None.' / '**Prior reviewer feedback:** None.'
Prior * = other authors. Mention once in Prior reviewer feedback, never restate in Findings.

Conclusion:
- No findings + no prior → APPROVED ✅
- Only MINOR → APPROVED WITH CAUTION ⚠️
- BLOCKER/MAJOR → NEEDS CHANGES ❌
- Unclear → NEEDS CLARIFICATION ❓"

# Build SYSTEM_PROMPT + USER_PROMPT globals.
# Args:
#   $1 incremental(0/1)  $2 noise_filtered(0/1)  $3 prior_review_sha
#   $4 head_sha          $5 pr_title             $6 pr_title_header
#   $7 pr_body           $8 full_repo            $9 pr_number
#   $10 pr_author        $11 pr_add              $12 pr_del
#   $13 pr_changed       $14 pr_base             $15 diff_base
#   $16 diff             $17 diff_truncated_note $18 changed_files
#   $19 commits_since    $20 callers_section     $21 reviews
#   $22 inline_comments  $23 issue_comments      $24 review_threads_active
build_prompts() {
  local incremental="$1" noise_filtered="$2" prior_review_sha="$3"
  local head_sha="$4" pr_title="$5" pr_title_header="$6" pr_body="$7"
  local full_repo="$8" pr_number="$9" pr_author="${10}"
  local pr_add="${11}" pr_del="${12}" pr_changed="${13}"
  local pr_base="${14}" diff_base="${15}"
  local diff="${16}" diff_truncated_note="${17}" changed_files="${18}"
  local commits_since="${19}" callers_section="${20}"
  local reviews="${21}" inline_comments="${22}" issue_comments="${23}"
  local review_threads_active="${24}"

  local header_full header_incremental template_full template_incremental
  local template mode_note commits_section
  local pr_title_for_prompt pr_body_for_prompt

  if (( noise_filtered )); then
    header_full="# PR #$pr_number Review"
    header_incremental="# PR #$pr_number Re-review (incremental)"
  else
    header_full="# PR #$pr_number Review — $pr_title_header"
    header_incremental="# PR #$pr_number Re-review (incremental) — $pr_title_header"
  fi

  template_full="$header_full

## 📝 Summary
<1-3 sentences.>

## 🔧 Changes Overview
- **<F#>** — <concrete change with \`symbols\`>
(≤6 bullets; cite by alias F1/F2/...)

## 🔍 Code Review
**Correctness:** <one sentence>
**Tests:** <coverage / gaps>
**Security & data integrity:** <auth, input, PII>
**Performance / regressions:** <hot paths, N+1>

**Prior reviewer feedback:** None.
**Findings:** None.
**Conclusion:** APPROVED ✅"

  template_incremental="$header_incremental

## 🆕 Commits since $prior_review_sha
- <sha7> <subject>

## 📝 Summary
<1-3 sentences.>

## 🔧 Changes Overview
- **<F#>** — <concrete change with \`symbols\`>
(≤6 bullets; cite by alias F1/F2/...)

## 🔍 Code Review
**Correctness:** <one sentence>
**Tests:** <coverage / gaps>
**Security & data integrity:** <auth, input, PII>
**Performance / regressions:** <hot paths, N+1>

**Prior reviewer feedback:** None.
**Findings:** None.
**Conclusion:** APPROVED ✅"

  if (( incremental )); then
    template="$template_incremental"
    mode_note="INCREMENTAL REVIEW. Prior review at \`$prior_review_sha\`. Current HEAD \`$head_sha\`. Focus only on diff since prior review. Skip MINOR/NIT findings."
  else
    template="$template_full"
    mode_note="FULL REVIEW (first time we are reviewing this PR)."
  fi

  if [[ -n "$commits_since" ]]; then
    commits_section="
## Commits since prior review
$commits_since"
  else
    commits_section=""
  fi

  if (( noise_filtered )); then
    pr_title_for_prompt="[redacted — references filtered files; review the diff]"
    pr_body_for_prompt="[redacted — references filtered files; review the diff]"
  else
    pr_title_for_prompt="$pr_title"
    pr_body_for_prompt="$pr_body"
  fi

  SYSTEM_PROMPT="$SYSTEM_PROMPT_TEXT"

  USER_PROMPT="$mode_note

PR metadata:
- Repo: $full_repo
- Number: $pr_number
- Title: $pr_title_for_prompt
- Author: @$pr_author
- Stats: +$pr_add / -$pr_del across $pr_changed files
- HEAD: $head_sha
- Base: $pr_base ($diff_base)

## PR description
$pr_body_for_prompt

## Changed files (aliased)
$changed_files

NOTE 1: Lockfiles, binaries, etc. are filtered as noise and not shown. PR title/description may reference excluded files — review only what is shown below. The diff is the source of truth.

NOTE 2: Paths in the diff have been replaced with short aliases (F1, F2, ...) to avoid tokenizer fragmentation. Cite findings using the alias (e.g. \"F1: handler omits null check\"). Real paths will be restored before posting.

## Diff (unified, U${HUNK_CONTEXT_LINES} context)${diff_truncated_note}

\`\`\`diff
$diff
\`\`\`
$commits_section

$callers_section

## Prior reviews
$reviews

## Prior inline review comments
$inline_comments

## Prior issue comments
$issue_comments

## Active review threads (unresolved, non-outdated)
$review_threads_active

---

Output the review markdown matching EXACTLY this template (replace angle-bracket placeholders, keep all section headers verbatim, end on the **Conclusion:** line — no footer, no horizontal rule, no date, no model name):

$template"
}
