# Design notes — why the plugin looks the way it does

Written 2026-04-23. These are the load-bearing decisions that were debated, settled, and locked in during planning. If you are about to contradict one of these, re-read the section first — the alternative was considered and rejected for a reason.

## 1. Per-Bash hook, not an outer wrapper

**What we chose.** A single `PreToolUse` hook matched to the `Bash` tool. Each Bash call Claude makes is rewritten to `try -D <overlay> -n -- bash -c <orig>`.

**What we rejected.** An outer shell wrapper (`trai`) that launches `claude` itself inside a `try` session.

**Why.**

- The outer wrapper captures **everything** — Bash *and* Claude's direct Edit/Write/MultiEdit file writes. That sounds better until you realize the overlay then contains Claude's own state (`~/.claude/`, logs, history) which must be filtered out of the commit.
- The outer wrapper is an entirely separate install path from Claude Code's extension model. Users have to `curl | sh` it or clone a repo, set up `$PATH`, and remember to invoke `trai` instead of `claude`. Plugin install is one slash command.
- The user was explicit in the planning conversation that they'd rather have a narrower-but-cleaner scope (Bash side-effects reversible; code edits reviewable via git). That's the scope we ship.

**Trade-off we accept.** Claude's `Edit` / `Write` / `MultiEdit` tools write through the Node process directly — they never become subprocess calls that a hook can intercept. So file edits to source code are **not** sandboxed. We document this loudly and rely on git for that half.

## 2. Plugin-only distribution. No wrapper, no curl-pipe-sh

**What we chose.** Everything ships inside the `.claude-plugin/` manifest + `hooks/` + `commands/` + `scripts/` tree. Users install with `/plugin marketplace add <git-url>` and `/plugin install trai`.

**What we rejected.** A separate shell tool distributed via install script or package manager.

**Why.** A plugin is installable, updatable, and uninstallable with two slash commands. A shell tool needs shellrc edits, uninstall scripts, version managers. The plugin format also means Claude Code knows about it — `/plugin list` shows it; disabling it cleanly removes all hooks. Trust surface is identical either way (both are shell scripts running with user privileges), but operational surface is smaller.

## 3. All-or-nothing commit in v1

**What we chose.** `/trai:commit` applies the full accumulated overlay. `/trai:discard --yes` nukes it. No per-file picker.

**What we rejected.** Per-file / per-hunk interactive commit.

**Why.** Per-hunk commit means a TUI, path-conflict resolution, synthesizing partial commits outside of `try commit`'s atomicity guarantees, and handling whiteout/rename tombstones. It's a week's work on its own, and git itself already solves partial-commit well once the overlay is applied. If a user wants selective: `/trai:commit`, then `git add -p`.

**Revisit when.** Users frequently hit the "I want only half of this" case and a git-less workflow is common enough to justify.

## 4. Linux-only, fail loudly on macOS and Windows

**What we chose.** `scripts/doctor.sh` refuses to start on non-Linux kernels and prints a pointer to Claude Code's native Seatbelt/bubblewrap sandbox. The `SessionStart` hook self-disables the plugin if doctor fails.

**What we rejected.** APFS-snapshot or `sandbox-exec` fallback on macOS; Docker-for-Desktop bootstrapping on any OS.

**Why.** `try` is Linux-only because overlayfs is Linux-only. APFS snapshots have completely different semantics (snapshot-of-volume, not overlay-per-process). `sandbox-exec` blocks but doesn't produce an inspectable diff. A Docker-in-Docker story works but multiplies the failure surface by the number of host configurations. v1 is Linux.

## 5. Shared overlay dir across all Bash calls in a session

**What we chose.** One overlay dir per Claude session, stored at `$XDG_STATE_HOME/trai/sessions/<id>/overlay/`. Every `try -D $overlay -n -- <cmd>` invocation reuses the same `upperdir`.

**What we rejected.** One overlay per Bash call (isolated upperdirs per-invocation).

**Why.** Per-call isolation breaks multi-call sequences: if call 1 `mkdir foo` and call 2 `cd foo && touch bar`, call 2's overlay doesn't see `foo` — it fails. Users and Claude both expect sequential commands to share state. The shared-overlay-per-session model is identical in spirit to a single shell: state accumulates, and the "review" at the end shows the net diff, not a log of intermediate states.

Per-call isolation is a hypothetical future "git-log-like" mode. Not v1.

## 6. Passthrough list for git / sudo / docker / read-only commands

**What we chose.** `config/defaults.json` lists command patterns that the hook does **not** wrap. `git *`, `gh *`, `sudo *`, `docker *`, `podman *`, plus read-only tools like `ls`, `cat`, `pwd`, `grep`, `rg`, `find`, `which`, `env`.

**Why per-pattern:**

- **`git *`** — users want git commits/diffs to hit the real repo. Wrapping git means Claude's "check `git status`" reports on the overlay's git state, which is the same repo's worktree via overlayfs, and branches/HEAD writes land in the overlay. Commits inside the overlay require `try commit` to propagate, which is surprising behavior. Let git talk to the real repo; users can always un-do by git.
- **`sudo *`** — `sudo` is a setuid binary and interacts poorly with unprivileged user namespaces. Wrapping opaquely fails with `sudo: effective uid is not 0`. Passthrough plus a user-visible warning is the least-surprising behavior.
- **`docker *`, `podman *`** — already container-based; nesting under `try` is a known-broken combination upstream (issue #19).
- **Read-only commands** (`ls`, `cat`, `grep`, `rg`, `find`, `which`, `env`, `pwd`, `echo`, `true`, `false`, `type`, `command`) — no side effects to review. Wrapping them adds 50–200ms per call for no benefit.

Users can override the list via `${CLAUDE_PLUGIN_DATA}/config.json`. The default list is deliberately conservative — we wrap too much rather than too little.

## 7. No default network isolation

**What we chose.** `try` is invoked without `-x`. Network remains accessible inside the sandbox.

**Why.** Claude needs the Anthropic API. `try -x` creates a new net namespace that severs *all* networking, including the API. A proxy-allowlist story is complex enough to be v2.

**Trade-off we accept.** A malicious agent with network access can exfiltrate data *before* the user reviews the overlay. This is the fundamental "post-hoc review is not a security boundary" limit. We document it and don't apologize for it — users who need exfil defense should use Claude Code's built-in network sandbox in addition to this plugin.

## 8. Plugin-internal scripts are exempt from the rewriter

**What we chose.** `hooks/pre-bash.sh` early-returns passthrough for any command whose first path is inside `$CLAUDE_PLUGIN_ROOT`.

**Why.** The seven `/trai:*` slash commands each expand to a `Bash(${CLAUDE_PLUGIN_ROOT}/scripts/cmd-*.sh)` tool call. Without exemption, `PreToolUse(Bash)` wraps those in `try`, which is *absurd*:

- `/trai:doctor` runs inside the overlay → reports on the overlay's view of the kernel / `try` / `jq`, not the real host.
- `/trai:passthrough` writes the bypass token into the overlay's upperdir, so the next real Bash call checks `$TRAI_BYPASS` on the host (which never got written) and the bypass silently fails.
- `/trai:commit` / `/trai:discard` operate on the overlay's view of the session pointer, leaving real state inconsistent.

Discovered live in production. The fix is a single early-return case in `pre-bash.sh`:

```bash
root="${CLAUDE_PLUGIN_ROOT%/}"
case "$cmd" in
  "$root"/*) trai::hook_passthrough "trai: plugin-internal script; not sandboxed."; exit 0 ;;
esac
```

## 9. Pre-clean `temproot/` before each `try` call

**What we chose.** Right before dispatching `try -D <overlay> <cmd>`, delete every non-directory entry under `<overlay>/temproot/`.

**Why.** Upstream `try`'s `sandbox_valid_or_empty()` (at line 558 of `vendor/try/try`) rejects any sandbox whose `temproot/` contains a file or symlink. But `try`'s own chroot setup creates symlinks under `temproot/` for every host mountpoint that is itself a symlink (e.g. `temproot/bin -> usr/bin` on systemd distros). Upstream's cleanup (around line 328) tries to remove them but isn't reliable — on duvel we reproduced two failure modes with reused `-D`:

1. `ln: failed to create symbolic link 'temproot//bin/bin': Permission denied` on the second Bash call (try re-creates the symlink, but the leftover causes the new `ln -s` to resolve into an overlay-mounted read-only dir).
2. `try: given sandbox 'X' is invalid` on the third call (validity check fires because non-directory entries remain).

User data lives in `upperdir/`, not `temproot/`, so wiping `temproot/`'s contents between calls costs nothing:

```bash
find "$overlay/temproot" -mindepth 1 -delete 2>/dev/null || true
```

This is a coping mechanism for an upstream limitation, not a fix. Upstream `try` was designed for single-command usage; our shared-overlay-per-session architecture pushes `-D` further than upstream tests for.

## 10. `SessionStart` is idempotent

**What we chose.** `hooks/session-start.sh` checks `current-session` first. If it already points at an existing overlay, emit a "resumed" banner and return early. Only create a new overlay when there's nothing to resume.

**Why.** `SessionStart` fires on `startup`, `resume`, `clear`, `compact`, **and auto-compact** — not just at genuine startup. The original implementation unconditionally called `trai::new_session()` on every fire, which:

- Overwrote `current-session` with a fresh empty overlay, orphaning any in-progress work. `/trai:status` then reported on the new empty overlay instead of the one the user's Bash calls had been landing in.
- If doctor happened to fail on re-run, the error path cleared `current-session` entirely — so `/trai:status` reported `"no active session"` mid-session, which is how we found this.

Idempotence is the right default for any lifecycle hook that creates persistent state. If you add other per-session state, check for existing state first.

## 11. Runtime state lives in `$XDG_STATE_HOME/trai/`, not `$CLAUDE_PLUGIN_DATA`

**What we chose.** `current-session` and `bypass-next` are written under `$XDG_STATE_HOME/trai/`. Only `config.json` (user-authored overrides) is read from `$CLAUDE_PLUGIN_DATA`.

**Why.** We discovered in live use that `$CLAUDE_PLUGIN_DATA` is unreliable for plugin-private runtime state:

- **NFS.** On hosts where `$HOME` is NFS-mounted (common on shared research machines), `$CLAUDE_PLUGIN_DATA` inherits `$XDG_DATA_HOME` which defaults to `$HOME/.local/share/trai` — also NFS. Writes silently fail or succeed with delayed visibility; the hook writes, and microseconds later the same path looks empty.
- **Context divergence.** `$CLAUDE_PLUGIN_DATA` has been observed to resolve differently between the hook-execution context (`pre-bash.sh` reads it one way) and the slash-command-execution context (`cmd-status.sh` reads it another way). The hook writes `current-session` in dir A; the status command reads from dir B; state "disappears."

We hit the second failure mode on duvel: `npm init` / `node` ran correctly sandboxed (meaning pre-bash.sh found the session pointer), and `/trai:status` *seconds later* reported "no active session" (meaning cmd-status.sh looked in a different place). The smoking-gun diagnostic:

```
CLAUDE_PLUGIN_DATA: /home/<user>/.local/share/trai      (NFS)
current-session:    ...current-session  (exists=no)
```

`$XDG_STATE_HOME` is different: the *user* sets it before launching claude, and it's inherited as an environment variable by every subprocess — hooks, slash commands, the `/plugin` harness. One value, one place.

**Implication for contributors.** Anything the plugin writes and later reads (session pointer, bypass token, future things like a gc timestamp) goes under `$TRAI_STATE_ROOT = $XDG_STATE_HOME/trai/`. `$CLAUDE_PLUGIN_DATA` is read-only from the plugin's side — only the user writes there (via `config.json`).

## Decision we revisit if evidence shows up

- Move the overlay from `$XDG_STATE_HOME` to `$XDG_CACHE_HOME` if users find overlays filling their backup-eligible state dirs.
- Switch from `flock` to an atomic-rename lock if `flock` misbehaves on remote filesystems (it does on some NFS versions).
- Drop `git` from the passthrough list if we find Claude is consistently confused about which repo state it's operating on. (No evidence yet.)
- Add `PostToolUse` diagnostic logging if debugging overlay issues becomes painful.

## Decision we do **not** revisit without strong evidence

- The per-Bash-hook model. If we change this, it's a different project.
- Plugin-only distribution. If we add a shell wrapper, we split the install story.
- Linux-only in v1. macOS support is a distinct product.
