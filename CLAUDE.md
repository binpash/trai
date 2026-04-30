# trai — repo context

This repo is a **Claude Code plugin** that sandboxes each `Bash` tool call through [binpash/try](https://github.com/binpash/try) so the user can review the accumulated filesystem diff after Claude finishes and choose to commit or discard.

## Scope decisions (locked; see `docs/design-notes.md` for why)

1. **Per-Bash hook, not outer wrapper.** `PreToolUse(Bash)` rewrites each `Bash(x)` → `Bash(try -D $overlay 'x')` — passing the full command as a **single** arg (not `bash -c '...'`) because `try` internals do `echo "$@"` which collapses multi-args. `-D` implies `-n`.
2. **Edit / Write / MultiEdit are NOT sandboxed.** They write through Node directly; hooks can't intercept them. Users rely on git for that half.
3. **Plugin-only distribution.** Installed via `/plugin marketplace add <git-url>`. No curl-pipe-sh, no wrapper binary.
4. **All-or-nothing commit in v1.** `/trai:commit` or `/trai:discard --yes`. Partial commits defer to `git add -p` post-commit.
5. **Linux-only.** Doctor refuses to start on macOS/Windows.
6. **Shared overlay per session.** One `-D` dir across all Bash calls so state accumulates. `pre-bash.sh` pre-cleans `temproot/` before each call because upstream `try`'s validity check (`sandbox_valid_or_empty`) refuses sandboxes with non-directory entries in `temproot/`.
7. **`git` / `sudo` / `docker` / read-only commands are passthrough** (not wrapped).
8. **No default network isolation** (`-x` not passed). Claude needs the API.
9. **Plugin-internal scripts self-exempt.** Any command starting with `$CLAUDE_PLUGIN_ROOT/` is passthrough. Required so `/trai:doctor` sees the real host, `/trai:passthrough` writes its token to the real FS, etc.
10. **`SessionStart` is idempotent.** Claude Code fires it on startup, `/clear`, `/compact`, `/resume`, and auto-compact. `session-start.sh` reuses an existing overlay if one is live; otherwise creates a fresh one.

## Load-bearing files

- `hooks/pre-bash.sh` — the rewriter. Reads Claude's `PreToolUse` JSON on stdin, emits `{hookSpecificOutput.updatedInput.command}` with the `try`-wrapped command. If you break this, nothing is sandboxed.
- `hooks/session-start.sh` — creates the overlay dir, writes `$XDG_STATE_HOME/trai/current-session`, runs `scripts/doctor.sh` in quiet mode. If doctor fails, writes empty `current-session` so the pre-bash hook self-disables.
- `hooks/session-end.sh` — prints a reminder banner if the overlay is uncommitted.
- `scripts/doctor.sh` — kernel / `unprivileged_userns_clone` / `try`-installed / `unshare` / FS-type preflight. Single source of truth for "is this environment compatible."
- `scripts/is-passthrough.sh` — matches a command against the passthrough patterns from `config/defaults.json`. Called from `pre-bash.sh`.
- `config/defaults.json` — default passthrough + ignore patterns. Users override via `$CLAUDE_PLUGIN_DATA/config.json`.
- `.claude-plugin/plugin.json` — plugin manifest.
- `.claude-plugin/marketplace.json` — single-plugin marketplace so `/plugin marketplace add <git-url>` works.
- `commands/*.md` — seven slash commands (`/trai:diff`, `/trai:commit`, `/trai:discard`, `/trai:explore`, `/trai:status`, `/trai:doctor`, `/trai:passthrough`).

## Conventions

- **Shell**: `bash`, `#!/usr/bin/env bash`, `set -euo pipefail`, prefer POSIX where practical.
- **Lint**: `shellcheck`-clean. Run `shellcheck hooks/*.sh scripts/*.sh` before committing.
- **JSON**: always through `jq`. Never hand-roll string-matching on JSON.
- **No runtime deps outside POSIX + `jq` + `flock` + `try` itself.** Explicitly no Node, no Python, no Go.
- **Paths**: always absolute inside scripts; use `${CLAUDE_PLUGIN_ROOT}`, `${CLAUDE_PLUGIN_DATA}`, `${CLAUDE_PROJECT_DIR}`.
- **Slash commands**: terse markdown with frontmatter; body is a one-liner `!…` shell invocation where possible, delegating to a helper script.
- **Tests**: `test/smoke.sh` is the end-to-end. Run it in a scratch dir (`$(mktemp -d)`), NEVER in this repo's own cwd — the smoke test commits and discards overlays.

## Hard guardrails

- **Do NOT** delete or rewrite an overlay dir without user confirmation. Programmatic `rm -rf` on `$XDG_STATE_HOME/trai/sessions/*` without the `--yes` interaction is a data-loss event. (Wiping `overlay/temproot/` contents is the one exception — that's `try`'s chroot scratch space and never holds user data.)
- **Do NOT** call `try commit` programmatically from any script that isn't explicitly the `/trai:commit` handler. Commit is a user decision.
- **Do NOT** add a runtime dependency on Node, Python, or any compiled binary other than `try` itself. The plugin must work on a minimal Debian container with `bash`, `jq`, `flock`, `unshare`, and `try`.
- **Do NOT** modify the user's `~/.claude/settings.json`. Plugin state lives in `${CLAUDE_PLUGIN_DATA}` only.
- **Do NOT** change the per-Bash-hook architecture without re-opening the planning conversation. If you think Edit/Write should be sandboxed, that's a different product; discuss before building.
- **Do NOT** default to network isolation (`-x`). Opt-in only, because it severs the Anthropic API.
- **Do NOT** remove the plugin-internal-script exemption at the top of `pre-bash.sh`. Without it, `/trai:doctor` reports on the overlay, `/trai:passthrough` silently fails, and `/trai:commit` writes the session pointer into the overlay instead of the real FS. Discovered live; don't re-break.
- **Do NOT** remove the pre-clean of `temproot/` in `pre-bash.sh`. Upstream `try` fails with "sandbox invalid" or `ln: Permission denied` on the 2nd+ call into a shared `-D` overlay without it. Also discovered live.
- **Do NOT** make `session-start.sh` unconditionally create a new overlay. `SessionStart` fires on `/compact` / `/clear` / `/resume` too; a fresh-every-time implementation orphans in-progress work.

## Gotchas discovered in real use (not during planning)

These all cost a debugging round in live sessions. They're written up fully in the docs; this is just the lookup table.

| Symptom | Cause | Fix location |
|---|---|---|
| Plugin fails to load: `Hook load failed: ... path ["hooks"] received undefined` | `hooks/hooks.json` event map must be wrapped under a top-level `"hooks"` key, like `settings.json`. | `hooks/hooks.json`; `docs/research-claude-code.md` §"Configuration shape" |
| `/trai:doctor` reports on an overlay, not the real host; `/trai:passthrough` silently fails | Plugin's own scripts getting sandboxed by the `PreToolUse(Bash)` hook | Self-exemption at top of `hooks/pre-bash.sh`; `docs/design-notes.md` §8 |
| `ln: failed to create symbolic link 'temproot//bin/bin': Permission denied` on 2nd Bash call | Leftover symlinks in `overlay/temproot/` from try's incomplete cleanup | Pre-clean in `hooks/pre-bash.sh`; `docs/design-notes.md` §9 |
| `try: given sandbox 'X' is invalid` on 3rd+ Bash call | `sandbox_valid_or_empty()` refuses temproot with any non-directory entries | Same pre-clean as above |
| `/trai:status` reports "no active session" mid-session after successful Bash calls | `SessionStart` re-fired on compact/resume and overwrote or cleared `current-session` | Idempotent bail-out in `hooks/session-start.sh`; `docs/design-notes.md` §10 |
| `/trai:status` reports "no active session" even on a first-invocation Claude session where Bash calls just ran sandboxed | Runtime state (current-session, bypass-next) was in `$CLAUDE_PLUGIN_DATA` which lands on NFS when `$HOME` is NFS and/or varies between hook and slash-command contexts | Moved runtime state to `$XDG_STATE_HOME/trai/`; `docs/design-notes.md` §11 |
| `cd: /home/user/...: No such file or directory` inside every sandboxed Bash call | User launched Claude from a cwd path that traverses NFS `$HOME`; `/home` couldn't be overlayed; the symlink doesn't resolve inside the chroot | Launch Claude from real local-disk path, set `XDG_STATE_HOME` to local disk; `docs/limitations.md` §11 |
| Overlay warnings about `/home`, `/run`, `/snap`, `/sys` | Cosmetic — `try` tries to overlay every top-level mountpoint and warns when it can't. Execution continues. | No fix needed; ignore |

## Where to read before changing things

- **What is `try`, how does it work, what breaks it?** → `docs/research-try.md`
- **How do Claude Code hooks / plugins / marketplaces work?** → `docs/research-claude-code.md`
- **Why post-hoc review at all, what did we decide not to do?** → `docs/research-review-ux.md`
- **Rationale for each locked-in decision** → `docs/design-notes.md`
- **Known failure modes and workarounds** → `docs/limitations.md`

## Local dev setup

- `try` is vendored as a git submodule under `vendor/try`. Build it with `make -C vendor/try`. `scripts/doctor.sh` will find it there as a fallback if no system `try` is on `$PATH`.
- Host requirements: Linux kernel ≥ 5.11, `unprivileged_userns_clone=1`, `jq`, `flock`, `unshare`.
- Run `test/smoke.sh` from a scratch dir to verify end-to-end.
