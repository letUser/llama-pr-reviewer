# pr-reviewer

Self-hosted PR review bot. Scans open PRs on a GitHub org, sends each diff to a
local llama-server, posts a structured review comment, and auto-approves on
clean runs.

No agent loop, no tool calls — one model invocation per PR. Tuned for fast,
deterministic batch review on a single GPU box.

## Pipeline

```
bin/scan-open-prs  → fills queue.tsv with eligible PRs, launches queue runner as
                     transient systemd --user unit (review-queue) ↓
bin/review-queue   → drains queue.tsv under flock, calls per PR, sends summary ↓
bin/review-pr      → fetches diff + context, calls llama-server, posts review,
                     erases llama-server slot 0 on exit to free VRAM
```

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
- A running [llama-server](https://github.com/ggml-org/llama.cpp) (OpenAI-compatible endpoint) with **~64K token context** (`CTX_SIZE` default). Reasoning models need headroom — prompt ≤ ~30K + `MAX_TOKENS` output budget (default 16K, raise for chatty reasoning models).
- `systemd --user` (only for the timer + `RESTART_LLAMA=1` auto-restart features)
- `openclaw` (optional, for queue start/done notifications via `NOTIFY_TARGET` — supports any channel openclaw exposes: telegram, whatsapp, etc.)

### Platform support

| OS | Status | Notes |
|----|--------|-------|
| Linux | supported | primary target |
| macOS | works with extras | `brew install bash flock coreutils` (coreutils provides `gdate`; scripts auto-detect). No `systemd` features (use launchd/cron manually). |
| Windows | WSL only | run inside WSL2 Linux |
| BSD | works with extras | needs `bash` 4+, `flock`, and GNU `date` (install `coreutils`, scripts pick up `gdate`). No `systemd` features. |

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
| `VERIFY_BOT` | — | GitHub login to `@`-mention at end of review |
| `RESTART_LLAMA` | `0` | Restart llama-server systemd unit between batches (frees VRAM) |
| `LLAMA_UNIT` | — | systemd --user unit name (required if `RESTART_LLAMA=1`) |
| `NOTIFY_TARGET` | — | Notification target ID for queue start/done events (requires `openclaw`). Empty = no notify |
| `NOTIFY_CHANNEL` | `telegram` | openclaw channel (`telegram`, `whatsapp`, etc — any channel openclaw supports) |
| `MAX_DIFF_BYTES` | `120000` | Diff truncation budget |
| `MAX_TOKENS` | `16384` | Output token cap (`n_predict`). Reasoning models burn tokens before answer — raise on `finish_reason=length` |
| `CTX_SIZE` | `65536` | llama-server context window. Worker aborts (exit 5) if prompt + `MAX_TOKENS` won't fit |
| `CTX_SAFETY_MARGIN` | `512` | Tokens kept free below `CTX_SIZE` |
| `PR_REVIEWER_HOME` | script dir | Override location of `.env`, `.cache`, `.share` |
| `WORKSPACE_BASE` | `$PR_REVIEWER_HOME/.share` | Override clone location |
| `WORKER` | sibling `review-pr` | Path to worker used by queue runner |
| `QUEUE_RUNNER` | sibling `review-queue` | Path to queue runner used by scanner |

Full list in `.env.example`.

## What the reviewer optimizes for

- **Triage gate**: lockfiles, binaries, minified, whitespace-only, dependency-only PRs auto-approved without calling the model.
- **Tight prompt**: U20 diff context, changed-symbol extraction + git grep caller hits, compact one-line comment summaries.
- **No prior-self echo**: the bot's own past comments (plus `SKIP_PRIOR_AUTHORS` + `VERIFY_BOT`) are filtered out so it never restates itself across re-reviews.
- **Active threads only**: unresolved, non-outdated review threads pulled via GraphQL — resolved/outdated ones ignored.
- **Incremental mode**: prior reviewed SHA inferred from the bot's last comment timestamp; only the new range is reviewed.
- **Strict template**: model output forced into a known shape; conclusion line drives auto-approve (only fires when `APPROVED` present and `NEEDS` absent).
- **VRAM hygiene**: each worker run erases llama-server slot 0 on exit; optional full `LLAMA_UNIT` restart between batches via `RESTART_LLAMA=1`.

## Notifications

When `NOTIFY_TARGET` + `NOTIFY_CHANNEL` are set, two messages per run are sent via `openclaw`:

1. **Queue start** (from `bin/scan-open-prs`): list of queued `repo#pr` items.
2. **Queue done** (from `bin/review-queue`): per-PR outcome line with emoji — ✅ approved, ⚠️ approved with caution, ❌ needs changes, ❓ needs clarification, 💬 commented, ⏭ skipped (already reviewed / author skipped), 🔥 worker failure — plus the PR URL.

## License

MIT — see `LICENSE`.
