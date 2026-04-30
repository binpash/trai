# `binpash/try` — research notes

Source of truth: <https://github.com/binpash/try>. Captured 2026-04-23.

## Elevator pitch

`try` is a Linux CLI utility that runs a command inside an overlayfs-backed sandbox so you can **inspect exactly what the command changed** and then choose to commit or discard those changes. It is not a container engine and not a security sandbox; it is the smallest possible primitive for "run this command, show me the diff, let me decide." No root required, no image to build, no daemon to manage — just `try <cmd>` and an overlay directory in `/tmp`.

## Isolation model

`try` uses two Linux kernel primitives:

- **Unprivileged user namespaces** via `unshare --user --map-root-user`. The process inside sees UID 0 inside the namespace while running as the invoking user on the host. This is what lets an unprivileged user call `mount` to stack an overlayfs.
- **`overlayfs`** with `lowerdir` (the real filesystem), `upperdir` (a fresh scratch dir), and `workdir` (overlayfs metadata). The overlay is mounted over top-level directories (`/`, `/usr`, `/home`, `/var`, `/opt`, `/srv`, …) so the sandboxed process sees a merged view. All writes go to `upperdir`; the lower layers are untouched.

On exit, the overlay persists on disk (in `/tmp/trai:XXXX/` by default or under a user-supplied `-D <dir>`). Changes are classified by walking the upperdir:

| marker | meaning                           |
|--------|-----------------------------------|
| `ad`   | file added (new path)             |
| `md`   | existing file modified            |
| `rd`   | directory created / replaced      |
| `de`   | file deleted (whiteout char-dev)  |
| `mo`   | moved / renamed                   |
| `ln`   | new symlink                       |

`try commit <overlay>` applies these to the live filesystem; `rm -rf <overlay>` discards.

### What is **not** sandboxed

- **Network.** No network namespace by default — the process reaches the real network, real DNS, real sockets. `try -x` adds `unshare --net` but that severs all networking, which breaks most realistic workloads.
- **IPC.** Shared memory, message queues, Unix sockets cross the boundary.
- **Capabilities.** The process inherits CAP_SYS_ADMIN within the namespace (needed for overlay mounts); this is enough to do damage via `mount` tricks if the binary is actively malicious.
- **Host processes.** `try` shares the PID namespace with the invoker by default; sandboxed processes can see and signal host ones.

`try`'s README says this explicitly: it is a *prototype*, not a sandbox in the defensive-security sense. The project's own framing is "trust-but-verify for things you want to run but inspect first."

## Subcommand / flag reference

Verified against the vendored tree (v0.2.0, commit `0f4e441`):

```
Usage: try [-nvhyx] [-i PATTERN] [-D DIR] [-U PATH] [-L dir1:dir2:...] CMD [ARG ...]
  -n                don't commit or prompt for commit (overrides -y)
  -y                assume yes to all prompts (overrides -n)
  -x                prevent network access (new netns)
  -i PATTERN        ignore paths that match PATTERN on summary and commit
  -D DIR            work in DIR (implies -n)
  -U PATH           path to unionfs helper (mergerfs, unionfs-fuse)
  -L dir1:dir2:...  merge multiple lower directories (implies -n)
  -v                version
  -h                help

Subcommands:
  try summary DIR
  try commit  DIR
  try explore DIR
```

Two important corrections from earlier web research:

1. **There is no `-c` auto-commit flag** (v0.2.0). Auto-commit is done by answering the interactive prompt, or via `-y` ("assume yes to all prompts").
2. **`-D DIR` implies `-n`.** We do not need to pass both. Our rewriter uses `try -D <overlay> <cmd> ...` without a separate `-n`.
3. **There is no `--` separator** before the command. Synopsis is `try <flags> CMD [ARGS]`; additional safety comes from `bash -c '<original>'` quoting.

The two flags we care about are `-D` (stable overlay path we can reference from slash commands; implies `-n`) and optionally `-i` for ignore patterns.

### Repeating the same overlay across invocations

Calling `try -D /path/to/overlay -n <cmd>` twice reuses the same `upperdir`. State accumulates: if call 1 `mkdir foo`, call 2 `cd foo && touch bar` sees `foo` and writes `bar` into the same upper layer. This is what makes per-Bash-call interception produce a coherent session-level diff.

## Requirements

- Linux kernel ≥ **5.11** for unprivileged overlayfs in user namespaces. Earlier kernels restrict overlayfs to root.
- `kernel.unprivileged_userns_clone = 1` sysctl. Default-on in Fedora and Arch; default-off on some Debian/Ubuntu variants since 23.10 (re-enable with `sudo sysctl kernel.unprivileged_userns_clone=1`).
- `unshare`, `mount` (util-linux).
- `attr` / `getfattr` for whiteout detection.
- Optional fallbacks: `fuse-overlayfs`, `unionfs-fuse`, `mergerfs` (for systems where kernel overlay stacking fails on nested mounts).

## Known failure modes

1. **Nested mounts.** If the top-level dirs `try` wants to stack contain bind mounts or different filesystems (e.g. `/home` on a separate partition, `/var/lib/docker` on a tmpfs, btrfs subvolumes under `$HOME`), overlayfs refuses to stack. Workaround: `try -U unionfs-fuse` or `try -U mergerfs` falls back to a FUSE-based union at 2–10× the latency.
2. **Running `try` inside Docker / LXC.** Needs `--privileged --userns=host` or it fails in `unshare`. Systemd sandbox flags (`PrivateMounts`, `ProtectSystem`) in a service unit also conflict.
3. **Long-running daemons.** Processes that outlive the `try` invocation (daemons bound to ports, persistent DBs, `npm run dev &`) leave the overlay in an ambiguous state — files are open in a mounted tree that the child still references. Commit works but the still-running process points at overlay paths that may now differ from live FS.
4. **AppArmor profiles on Ubuntu 24.04+** can block unprivileged `unshare`/`mount`. Symptom is `EACCES: /proc/self/setgroups`. Fix: relax the AppArmor profile for the `unshare` binary or the user's home.
5. **Sudo inside the sandbox** fails opaquely because the setuid binary interacts poorly with the user-namespace UID mapping. Don't wrap sudo calls.
6. **Large builds** (`cargo build`, `npm install` on big deps) produce huge upperdirs — multiple GBs is normal. `/tmp` on tmpfs-backed systems will OOM.
7. **Prototype status.** Upstream has 30+ open issues around edge cases; not every distro/kernel combination works. Expect quirks.

## Install snippets

```bash
# Debian / Ubuntu
sudo apt install -y util-linux attr libfuse2
git clone https://github.com/binpash/try.git /tmp/try
cd /tmp/try && autoconf && ./configure && make && sudo make install

# Fedora
sudo dnf install -y util-linux attr fuse
# then same ./configure && make && sudo make install

# Arch
yay -S try               # AUR; or build from source as above

# Nix
nix-env -iA nixos.try    # or `nix run nixpkgs#try`

# Or vendor as a submodule (our approach in this repo)
git submodule add https://github.com/binpash/try vendor/try
cd vendor/try && autoconf && ./configure && make
# use ./vendor/try/try directly; doctor.sh will fall back to it
```

## Version we pin against

- **Tag**: `v0.2.0` (2023-07-24) as the minimum supported baseline. Earlier tags lack the `-i` ignore flag and `-D` stable overlay dir semantics we rely on.
- **`main` branch** is acceptable for development but upstream sometimes lands rename/semantics changes; our `scripts/doctor.sh` asserts a minimum `try --version` and refuses to start the session on mismatch.
- Vendored submodule in this repo (`vendor/try`) will be pinned to a specific commit; bump it deliberately.

## Community usage

As of April 2026: 5k+ stars, active issue tracker, no known first-class AI-agent integration. Common use cases in issues / blog posts are one-shot package-manager tests (`try apt install foo`), config-file edits, and teaching materials about overlayfs. Our integration appears to be the first substantial "hook into an AI coding agent" consumer.

## Reference links

- Repo: <https://github.com/binpash/try>
- Motivation / design post: Benjamin Oakes, "Do, or do not. There is no try" (2023-06-25) — <http://www.benjaminoakes.com/2023/06/25/binpashtry-Do-or-do-not-There-is-no-try-Were-setting-out-to-change-that/>
- Nested-mount issue (#19): <https://github.com/binpash/try/issues/19>
- Overlayfs merging issue (#123): <https://github.com/binpash/try/issues/123>
- LWN on user namespaces + overlayfs: <https://lwn.net/Articles/671641/>
