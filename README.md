# pr-reviewer

Self-hosted PR review bot. Scans open PRs on a GitHub org, sends each diff to a
local llama-server, posts a structured review comment, and auto-approves on
clean runs.

No agent loop, no tool calls — one model invocation per PR. Tuned for fast,
deterministic batch review on a single GPU box.

## Hardware requirements

Designed to run fully local on consumer GPUs. Reference target: **8 GB VRAM +
32 GB RAM** running a 30B MoE coder model (3B active params) with experts on
CPU via `-cmoe`.

| Tier | VRAM | RAM | Model | Offload | KV cache | Context | Throughput |
|------|------|-----|-------|---------|----------|---------|------------|
| Minimum | 6 GB | 16 GB | 9B Q4 dense | `-ngl 18` | Q8 K / Q4 V | 32K | ~500–800 changed LOC per review |
| **Reference** | **8 GB** | **32 GB** | **Qwen3-Coder 30B-A3B Q4 (MoE)** | `-ngl 99 -cmoe` (experts on CPU) | Q8 K / Q8 V | **64K** | **~3K LOC per review, ~25 t/s TG, ~200 t/s PP** |
| Alt-Reference | 8 GB | 16 GB | 9B Q4 dense reasoning | full (`-ngl 33`) + `-fa on` | Q8 K / Q4 V | 64K | ~3K LOC, ~40 t/s TG but verbose 6K-token reasoning output |
| Headroom | 12–24 GB | 32–64 GB | 30B-A3B Q5/Q6 or 70B Q4 | full | Q8 / F16 | 128K+ | Larger diffs, higher quant quality, sub-30s typical review |

The 8 GB / 32 GB row is the actively tested configuration. The MoE strategy
(small attention/shared on GPU, experts streamed from RAM) needs ~12 CPU
threads — match `--threads N` to your physical core count for ~3× TG over the
default thread setting.

Host requirements are minimal: `bash`, `jq`, `curl`, `git`. No GPU-side
dependencies beyond `llama-server`. Tuning flags and `.env` values for each
tier are in [Example: 8 GB VRAM + 32 GB RAM with Qwen3-Coder 30B-A3B MoE](#example-8-gb-vram--32-gb-ram-with-qwen3-coder-30b-a3b-moe-recommended).

## Pipeline

```
bin/scan-open-prs  → fills queue.tsv with eligible PRs, launches queue runner as
                     transient systemd --user unit (review-queue) ↓
bin/review-queue   → drains queue.tsv under flock, calls per PR, sends summary ↓
bin/review-pr      → fetches diff + context, calls llama-server, posts review,
                     erases llama-server slot 0 on exit to free VRAM
```

`bin/review-pr` is an orchestrator. Heavy lifting lives in `lib/`:

| File | Responsibility |
|------|----------------|
| [`lib/config.sh`](lib/config.sh) | `.env` loading, budget defaults, `NOISE_PATHSPECS`, GNU `date` detection |
| [`lib/triage.sh`](lib/triage.sh) | Noise / dep-manifest / whitespace-only classification, auto-approve skip path |
| [`lib/diff.sh`](lib/diff.sh) | Diff stripping, file-alias (`F1`/`F2`/…) build & apply & restore, changed-symbol + caller extraction |
| [`lib/github.sh`](lib/github.sh) | Prior reviews / inline / issue comments + GraphQL active review threads |
| [`lib/prompt.sh`](lib/prompt.sh) | `SYSTEM_PROMPT`, review templates, `USER_PROMPT` assembly |
| [`lib/llama.sh`](lib/llama.sh) | `/tokenize` preflight, ctx budget enforcement, SSE streaming, output validation, VRAM cleanup |

### Worker exit codes (`bin/review-pr`)

| Code | Meaning |
|------|---------|
| `0` | Review posted (or triage-skip auto-approved) |
| `100` | Skipped — already reviewed at current HEAD |
| `101` | Skipped — PR author in `SKIP_AUTHORS` |
| `4` | Model output missing `Conclusion:` line |
| `5` | Prompt + `MAX_TOKENS` exceed `CTX_SIZE - CTX_SAFETY_MARGIN` |
| other | Worker failure |

The queue runner uses these to classify each PR in the completion summary.

## Requirements

- `bash` 4+
- [`gh`](https://cli.github.com/) (authenticated: `gh auth login`)
- `jq`
- `curl`, `awk`, `sed`, `git`, `flock`
- A running [llama-server](https://github.com/ggml-org/llama.cpp) (OpenAI-compatible endpoint) with **64K token context** (`CTX_SIZE` default; raise to 128K for very large PRs at the cost of partial offload and slower TG). Default coder MoE config: prompt ≤ ~47K + `MAX_TOKENS` output budget (default 16K). For reasoning fallback models, raise `MAX_TOKENS` to 24576+ for chain-of-thought headroom.
- `systemd --user` (only for the timer + `RESTART_LLAMA=1` auto-restart features)
- `openclaw` (optional, for queue start/done notifications via `NOTIFY_TARGET` — supports any channel openclaw exposes: telegram, whatsapp, etc.)

### Platform support

| OS | Status | Notes |
|----|--------|-------|
| Linux | supported | primary target |
| macOS | works with extras | `brew install bash flock coreutils` (coreutils provides `gdate`; scripts auto-detect). `scan-open-prs` falls back to `nohup` when `systemd --user` absent; schedule it via `launchd`/`cron`. |
| Windows | WSL only | run inside WSL2 Linux |
| BSD | works with extras | needs `bash` 4+, `flock`, and GNU `date` (install `coreutils`, scripts pick up `gdate`). `scan-open-prs` uses `nohup` fallback; schedule via `cron`. |

## Setup

```bash
git clone https://github.com/letUser/llama-pr-reviewer.git
cd llama-pr-reviewer
cp .env.example .env
$EDITOR .env        # set OWNER, REPOS, LLAMA_URL, LLAMA_MODEL
```

Required env vars (see `.env.example`):
- `OWNER` — GitHub org/user that owns the repos
- `REPOS` — space-separated repo names under `$OWNER`
- `LLAMA_URL` — llama-server OpenAI endpoint (e.g. `http://127.0.0.1:8082`)
- `LLAMA_MODEL` — model name advertised by llama-server

## Usage

### One-shot review of a single PR

```bash
./bin/review-pr <repo> <pr_number>
```

### Scan + queue + drain (manual)

```bash
./bin/scan-open-prs      # finds eligible open PRs, fills queue, starts queue
```

### Scheduled scan via systemd --user

Unit templates in `systemd/` use `@INSTALL_DIR@` placeholders. `bin/install-systemd` renders them with this checkout's absolute path into `~/.config/systemd/user/`:

```bash
./bin/install-systemd
systemctl --user enable --now pr-scan.timer
```

Moving the repo? Re-run `./bin/install-systemd` from the new location.

Default cadence: every 30 minutes (edit timer to taste).

## Config knobs (highlights)

| Var | Default | Purpose |
|-----|---------|---------|
| `LOOKBACK_HOURS` | `12` | Only consider PRs created within last N hours |
| `SKIP_BASE_REFS` | `main,master` | Base refs to skip (exact match) |
| `SKIP_BASE_PREFIXES` | `release/` | Base ref prefixes to skip |
| `SKIP_AUTHORS` | — | PR authors to skip entirely |
| `SKIP_PRIOR_AUTHORS` | — | Comment authors whose prior reviews are hidden from model |
| `VERIFY_BOT` | — | GitHub login of verifier bot to `@`-mention at end of review (no `@`) |
| `RESTART_LLAMA` | `0` | Restart llama-server systemd unit between batches (frees VRAM) |
| `LLAMA_UNIT` | — | systemd --user unit name (required if `RESTART_LLAMA=1`) |
| `NOTIFY_TARGET` | — | Notification target ID for queue start/done events (requires `openclaw`). Empty = no notify |
| `NOTIFY_CHANNEL` | `telegram` | openclaw channel (`telegram`, `whatsapp`, etc — any channel openclaw supports) |
| `MAX_DIFF_BYTES` | `160000` | Diff truncation budget (soft cap) |
| `OVERSIZE_DIFF_BYTES` | `240000` | Hard cap. Above this, model is skipped; reviewer posts "needs human review" + `@BOT_OWNER` mention |
| `BOT_OWNER` | — | GitHub login of bot owner to `@`-mention (no `@`) |
| `MAX_TOKENS` | `16384` | Output token cap (`n_predict`). Reasoning models burn tokens before answer — raise on `finish_reason=length` |
| `CTX_SIZE` | `65536` | llama-server context window. Worker aborts (exit 5) if prompt + `MAX_TOKENS` won't fit |
| `CTX_SAFETY_MARGIN` | `2048` | Tokens kept free below `CTX_SIZE` |
| `PR_REVIEWER_HOME` | script dir | Override location of `.env`, `.cache`, `.share` |
| `WORKSPACE_BASE` | `$PR_REVIEWER_HOME/.share` | Override clone location |
| `WORKER` | sibling `review-pr` | Path to worker used by queue runner |
| `QUEUE_RUNNER` | sibling `review-queue` | Path to queue runner used by scanner |

Full list in `.env.example`.

## Tuning for diff coverage

How much code each PR review can ingest is bounded by:

```
prompt_token_budget = CTX_SIZE - CTX_SAFETY_MARGIN - MAX_TOKENS
```

The prompt holds the diff, changed-symbol context, active review threads, and the
template. Diff bytes-to-tokens ratio is ~2.8–3.5 for code. Worker aborts (exit 5)
if the assembled prompt won't fit.

`MAX_DIFF_BYTES` is a soft truncation cap on the diff alone — diffs above it
are truncated and still reviewed. Set it so the worst-case (truncated) diff
still leaves room for the rest of the prompt.

`OVERSIZE_DIFF_BYTES` is a hard cap. Above it, the model is skipped entirely —
the reviewer posts a `**Conclusion:** NEEDS_REVIEW` comment that `@`-mentions
`BOT_OWNER` to trigger a GitHub notification. Use this for mega-PRs where
truncated review is worse than no review.

`HUNK_CONTEXT_LINES` is the `-U<N>` passed to `git diff`. Higher values bloat
tokens without proportional quality gain:

- `U3` (default) — git/gh standard. What CodeRabbit, Claude, Copilot use. Recommended.
- `U5` — marginal extra context. Acceptable ceiling.
- `>U5` — diminishing returns; ships redundant lines, eats prompt budget.

### Failure modes

| Exit | Cause | Fix |
|------|-------|-----|
| `4` | Reasoning model burned all `MAX_TOKENS` before writing the `Conclusion:` line | Cap thinking with llama-server `--reasoning-budget`, raise `MAX_TOKENS`, or shrink the prompt |
| `5` | Prompt + `MAX_TOKENS` exceed `CTX_SIZE - CTX_SAFETY_MARGIN` | Lower `MAX_DIFF_BYTES`, lower `HUNK_CONTEXT_LINES`, lower `MAX_TOKENS`, or raise `CTX_SIZE` |

### Reasoning model llama-server flags

For chain-of-thought (CoT) models (Qwen reasoning variants, DeepSeek-R1, etc.) the
model can spend all of `MAX_TOKENS` on internal thinking before emitting the
answer — exit 4. Three llama-server flags address this:

- `--reasoning-budget N` — hard cap on thinking tokens. After N, llama-server
  forces end-of-thinking and the model writes its answer. `N=8000` works well
  for small-to-medium reasoning models on PR review (deep enough for real
  analysis, bounded enough to leave room in `MAX_TOKENS` for the review markdown).
  Larger budgets (16000+) often spent on repetition loops, not extra signal.
- `--reasoning-format deepseek` — routes thoughts to
  `message.reasoning_content` and leaves `message.content` as the clean final
  answer. The worker also strips `<think>` blocks defensively, but using
  `deepseek` is the correct setup.
- `--dry-multiplier 0.8 --dry-base 1.75 --dry-allowed-length 4` — DRY sampler
  penalizes repeated n-grams. Helps small reasoning models that loop on
  "Wait, ..." / "Let me check ..." inside the CoT. `allowed-length 4` is safe
  for code (avoids hurting short syntactic repeats like `})`).
- `--repeat-penalty 1.1 --repeat-last-n 256` — classic n-gram repeat penalty
  over a wider window. Catches paragraph-level loops that DRY misses (e.g. the
  same "Wait, one more check:" block re-emitted every ~150 tokens). The
  256-token window is large enough to span a typical loop period without
  hurting legitimate cross-section repeats (filenames cited in two sections,
  section headers). `1.1` is gentle — `1.2+` starts distorting verbatim
  template adherence.

If your llama-server build lacks `--reasoning-budget`, fall back to oversizing
`MAX_TOKENS` (e.g. `49152`) and accept longer review wall time.

### Example: 8 GB VRAM + 32 GB RAM with Qwen3-Coder 30B-A3B MoE (recommended)

llama-server flags:

```
-m Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf \
-ngl 99 \
-cmoe \
--threads 12 --threads-batch 12 \
-c 65536 \
-fa on \
--cache-type-k q8_0 --cache-type-v q8_0
```

`-cmoe` keeps all 128×48 expert tensors on CPU; only attention/shared layers +
KV cache live on GPU. Lands around **5.5 GB VRAM + ~20 GB RAM** for the model.
`--threads 12` matches the physical core count of a Ryzen 7 5800H (8c/16t) —
default is 8, raising to 12 gives a ~3× TG bump because MoE expert matmuls run
on CPU.

Non-reasoning coder model — no `--reasoning-budget` / `--reasoning-format`
needed. Output is direct (~300–500 tokens for a typical review vs 5–6K for a
reasoning model), so wall-clock is dominated by prompt eval, not generation.
No `--dry-*` or `--repeat-penalty` either — those defend against CoT
repetition loops that only happen in small reasoning models. On a specialized
coder they risk penalizing legitimate code repetition (`}\n})`, repeated
imports, identical param names).

Expected throughput: **~200 t/s PP, ~25 t/s TG, sub-minute reviews** for
sub-1K-LOC PRs.

Then in `.env`:

```bash
CTX_SIZE=65536
CTX_SAFETY_MARGIN=2048
MAX_TOKENS=16384
HUNK_CONTEXT_LINES=3
MAX_DIFF_BYTES=160000
OVERSIZE_DIFF_BYTES=240000
```

Prompt budget: `65536 - 2048 - 16384 = 47104` tokens ≈ ~150 KB of diff
possible (capped earlier by `MAX_DIFF_BYTES`), ~3K changed lines per review.

#### Alt: 9B dense reasoning model on 8 GB VRAM

If you don't have 32 GB RAM or prefer a single-card all-GPU setup, the older
9B reasoning config still works:

```
-m Qwen3.5-9B-Q4_K_M.gguf \
-ngl 33 \
-c 65536 \
-fa on \
--cache-type-k q8_0 --cache-type-v q4_0 \
--reasoning-format deepseek \
--reasoning-budget 8000 \
--dry-multiplier 0.8 \
--dry-base 1.75 \
--dry-allowed-length 4 \
--repeat-penalty 1.1 \
--repeat-last-n 256
```

```bash
CTX_SIZE=65536
MAX_TOKENS=24576          # ~8K thinking + ~16K answer headroom
```

~40 t/s TG, but the reasoning model burns 5–6K tokens per review (vs ~400 for
the coder MoE), so wall-clock is ~4–6× slower despite higher TG.

#### 128K context variant for the coder MoE

If you regularly hit 3K+ LOC PRs and need a bigger window with the same coder
model, drop V cache to q4 to keep VRAM in budget:

```
-m Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf \
-ngl 99 \
-cmoe \
--threads 12 --threads-batch 12 \
-c 131072 \
-fa on \
--cache-type-k q8_0 --cache-type-v q4_0
```

```bash
CTX_SIZE=131072
MAX_TOKENS=16384
MAX_DIFF_BYTES=240000
OVERSIZE_DIFF_BYTES=360000
```

KV cache jumps from ~3.2 GB (64K Q8/Q8) to ~4.8 GB (128K Q8/Q4) — fits the
~6 GB VRAM budget left after attention/shared layers. TG drops slightly
(~20 t/s) because KV reads scale linearly with context fill. For repos where
the OVERSIZE_DIFF_BYTES routing already captures the outlier mega-PRs, stick
with the 64K default — wall-clock will be faster on the common case.

## What the reviewer optimizes for

- **Triage gate**: lockfiles, binaries, minified, whitespace-only, dependency-only PRs auto-approved without calling the model.
- **Noise filter**: lockfiles, binaries, snapshots, fonts, and CHANGELOGs are excluded from the diff sent to the model. Pathspec list lives in `NOISE_PATHSPECS` in [`lib/config.sh`](lib/config.sh) — edit there to add/remove patterns. When any file is filtered, the PR title and description are also redacted in the prompt (they often reference excluded files, which would otherwise spiral the model into "the diff doesn't match the title" loops).
- **File-alias substitution**: every changed file path is replaced with a short alias (`F1`, `F2`, …) in the diff and caller-hits sections sent to the model. Small reasoning models fragment long compound paths (digit runs in migration timestamps, CamelCase filenames) and spiral on re-reading them — short stable aliases dodge the tokenizer issue. After the model emits its review (citing `F1`/`F2`), the worker post-processes `REVIEW_MD` to restore real paths. Findings cite by alias only — no line numbers — and a belt-and-braces `perl` strip removes any `line 1234` / `(line 35)` / trailing `:1234` the model might leak.
- **PR title sanitization**: brackets and parens are stripped before injecting the title (`[PROJ-1234]` → `PROJ-1234`). Stops tokenizer-attention spirals on bracketed Jira IDs.
- **Tight prompt**: configurable diff context, changed-symbol extraction + git grep caller hits, compact one-line comment summaries.
- **No prior-self echo**: the bot's own past comments (plus `SKIP_PRIOR_AUTHORS` + `VERIFY_BOT`) are filtered out so it never restates itself across re-reviews.
- **Active threads only**: unresolved, non-outdated review threads pulled via GraphQL — resolved/outdated ones ignored.
- **Incremental mode**: prior reviewed SHA inferred from the bot's last comment timestamp; only the new range is reviewed.
- **Streaming with newline-safe parser**: SSE deltas are appended directly to `$PR_REVIEWER_HOME/.cache/last-content.txt` and `last-reasoning.txt` (bash `$(...)` strips trailing newlines, which would flatten the review's markdown — the worker uses pipe-to-file instead). Tail those files to watch generation live.
- **Strict template + relaxed conclusion regex**: model output forced into a known shape; auto-approve grep matches both `**Conclusion:**` and plain `Conclusion:` (small reasoning models sometimes drop the markdown bold) and triggers when `APPROVED` is present and `NEEDS` absent.
- **Anti-loop prompt + sampler**: SYSTEM_PROMPT tells the model to commit fast — one pass through the diff, no re-walking, no re-quoting constraints, no template re-verification. Paired with llama-server `--repeat-penalty 1.1 --repeat-last-n 256` to catch paragraph-level "Wait, one more check:" loops.
- **Trust-first-read clamp**: small reasoning models suffer tokenizer fragmentation on re-reads of the diff — same line looks different each pass, hallucinating missing `this.`, trailing commas, broken brackets, or identifier mismatches. SYSTEM_PROMPT explicitly forbids flagging any syntax-level concern found on a re-read: "the actual code compiles; trust your first read." Prevents the worst failure mode (false-positive MAJOR findings that flip APPROVED → NEEDS CHANGES based on phantom bugs).
- **Stray `</think>` strip**: when the model leaks chain-of-thought into the `content` channel without an opening `<think>` tag (closing tag only), the worker drops everything up to and including the closing tag before posting.
- **Conclusion emoji normalization**: small reasoning models often drop the U+FE0F variation selector on `⚠️`, emitting a bare U+26A0. The worker post-processes `REVIEW_MD` to re-attach VS16 so the GitHub comment renders consistently. `✅` `❌` `❓` are single codepoints and unaffected.
- **File-based JSON / curl bodies**: prompts > ~128 KB blow past `ARG_MAX` when passed via `jq --arg` or `curl -d`. The worker writes system/user prompts to temp files in `.cache/` and uses `jq --rawfile` + `curl --data-binary @file` so large PRs don't trip the kernel limit.
- **VRAM hygiene**: each worker run erases llama-server slot 0 on exit; optional full `LLAMA_UNIT` restart between batches via `RESTART_LLAMA=1`.

## Debugging

Per-run streaming artifacts land in `$PR_REVIEWER_HOME/.cache/` (default: `pr-reviewer/.cache/`). Overwritten on every run.

| File | Contents |
|------|----------|
| `last-stream.sse` | Raw SSE response from `/v1/chat/completions` — usage block, finish_reason, every delta |
| `last-content.txt` | Concatenated `delta.content` — the review markdown the model emitted |
| `last-reasoning.txt` | Concatenated `delta.reasoning_content` — empty for non-reasoning models (expected) |
| `req-body.json` | Final `/v1/chat/completions` request body sent to llama-server |
| `req-sys.txt` | System prompt portion of the request (rawfile'd into `req-body.json`) |
| `req-user.txt` | User prompt portion of the request (rawfile'd into `req-body.json`) |
| `preflight-req.json` | Pre-send request payload used by `/tokenize` ctx-budget check |
| `preflight-content.txt` | Pre-send user-prompt content snapshot used by the preflight check |
| `review.lock` | `flock` worker lock — serializes `bin/review-pr` runs |
| `queue.lock` | `flock` queue lock — serializes `bin/review-queue` drains |

Watch generation live:

```bash
tail -f pr-reviewer/.cache/last-content.txt
tail -f pr-reviewer/.cache/last-reasoning.txt   # reasoning models only
```

Inspect token usage / finish reason of the last run:

```bash
grep '^data: ' pr-reviewer/.cache/last-stream.sse \
  | sed 's/^data: //' \
  | jq -rs 'map(select(.usage)) | last | .usage'
```

Common exit-4 triage:

- `last-content.txt` empty + `last-reasoning.txt` large → reasoning budget eaten before answer. Cap with `--reasoning-budget`, raise `MAX_TOKENS`, or shrink prompt.
- `last-content.txt` populated but missing `**Conclusion:**` → model drifted off template. Inspect tail, then lower temperature or tighten `SYSTEM_PROMPT`.
- Both empty → server error. Check `last-stream.sse` head for HTTP/JSON error from llama-server.

Non-reasoning models: `last-reasoning.txt` stays empty; this is normal. The worker's `reasoning_content // ""` jq fallback handles the absent field — no behavior change.

## Notifications

When `NOTIFY_TARGET` + `NOTIFY_CHANNEL` are set, two messages per run are sent via `openclaw`:

1. **Queue start** (from `bin/scan-open-prs`): list of queued `repo#pr` items.
2. **Queue done** (from `bin/review-queue`): per-PR outcome line with emoji — ✅ approved, ⚠️ approved with caution, ❌ needs changes, ❓ needs clarification, 💬 commented, ⏭ skipped (already reviewed / author skipped), 🔥 worker failure — plus the PR URL.

## Limitations

Tested against Qwen3-Coder-30B-A3B (UD-Q4_K_XL) as the primary model and
Qwen3.5-9B-Q4_K_M as the fallback. Output quality and behavior scale with model
size and quality. Specific known issues:

- **PR size ceiling**: at the 64K-ctx default the practical cap is ~3K changed LOC. Above that, small models burn output budget on filename / identifier fragmentation loops before emitting the review. Very large refactors will need manual review (or per-file chunking — not implemented yet); `OVERSIZE_DIFF_BYTES` already routes the worst offenders to the human path.
- **Tokenizer-induced spiral**: the model sometimes re-reads the diff and "sees" hallucinated typos (missing `this.`, stray commas, broken brackets). The trust-first-read clamp in SYSTEM_PROMPT suppresses these as findings, but the wasted reasoning tokens still count against `MAX_TOKENS` and slow wall-clock time.
- **Citation precision**: findings cite by filename only (no line numbers). Restoring exact paths is reliable via the F1/F2 alias system; line numbers are dropped because small models can't read hunk offsets without recomputing them and getting them wrong.

## License

MIT — see `LICENSE`.
