# trai

A Claude Code plugin that sandboxes **Bash tool calls** through
[binpash/try](https://github.com/binpash/try) so the filesystem side-effects of
shell commands stay in an overlay until you review them. At session end (or when you are ready to commit), run
`/trai:diff` to see the accumulated changes and `/trai:commit` or `/trai:discard`
to apply or throw them away.

**Linux only.** Requires kernel ≥ 5.11 and unprivileged user namespaces.

---

## Example

> **You:** Set up a Python virtualenv and install `requests` and `pytest`.

Claude runs `python3 -m venv .venv` and `pip install requests pytest` — but
nothing has touched your real filesystem yet. The writes are held in an overlay.

> **You:** `/trai:diff`

```
.venv/bin/activate (added)
.venv/lib/python3.11/site-packages/requests/ (created dir)
.venv/lib/python3.11/site-packages/pytest/ (created dir)
… 40 more files
```

> **You:** Looks good. `/trai:commit`

Now the virtualenv is on disk. If the install had gone wrong, `/trai:discard --yes`
would have left your project completely untouched.

---

## What this actually does

- Registers a `PreToolUse(Bash)` hook that rewrites every Bash command Claude
  issues from `npm install` to `try -D <overlay> 'npm install'`.
- Every command in the session shares one overlay dir under
  `$XDG_STATE_HOME/trai/sessions/<id>/` so sequential commands see each
  other's state coherently (call 2 sees files call 1 created).
- Read-only and git-related commands (see `config/defaults.json`) pass through
  unwrapped.
- At end of session, `/trai:diff` shows the accumulated diff and `/trai:commit`
  applies it to the real filesystem.

## What this does **not** do

- **Does not sandbox `Edit` / `Write` / `MultiEdit` tool calls.** Those write
  directly through Claude's Node process; our Bash hook can't intercept them.
  Use git to review and revert direct code edits.
- **Not a security sandbox.** Network is unrestricted; a compromised agent can
  exfiltrate before you see any diff. For security isolation use Claude Code's
  built-in bubblewrap/Seatbelt sandbox in addition.
- **Does not wrap `sudo`, `docker`, `podman`.** They fail opaquely inside an
  unprivileged user namespace and are explicitly passthrough.
- **Not tested with concurrent Claude sessions.** One overlay is shared across
  all Bash calls; running multiple Claude sessions simultaneously against it is
  not tested. The expected usage is a single Claude agent per session.

Full list: [`docs/limitations.md`](docs/limitations.md).


---

## Install

### Prerequisites

- Linux kernel ≥ 5.11, unprivileged user namespaces enabled.
- `bash`, `jq`, `flock`, `unshare` (util-linux).
- `try` (either on `$PATH` or as the vendored submodule; see below).

On Debian/Ubuntu:

```sh
sudo apt install -y util-linux attr jq bsdextrautils
```

### Install the plugin

```sh
# In a running Claude Code session:
/plugin marketplace add https://github.com/binpash/trai
/plugin install trai
/trai:doctor
```

If `/trai:doctor` reports that `try` is missing, install it:

```sh
git clone https://github.com/binpash/try.git /tmp/try
cd /tmp/try && autoconf && ./configure && make && sudo make install
```

Or use the vendored copy: this repo includes `vendor/try` as a submodule. If
you install the plugin from a git clone (not the marketplace), run:

```sh
cd <your clone> && git submodule update --init vendor/try
```

`scripts/doctor.sh` falls back to `vendor/try/try` if no system `try` is on
`$PATH`.




---

## Usage

Once installed, there is nothing to do — the plugin activates on every Claude
Code session and sandboxes your Bash calls transparently. At any point:

> **Tip for best results:** before starting a work session, feed Claude the
> [`claude-trai-guide.md`](claude-trai-guide.md) file from this repo. It
> gives Claude the context it needs to correctly interpret `/trai:diff` output,
> understand what is and isn't sandboxed, and avoid common gotchas:
>
> ```
> /read claude-trai-guide.md
> ```

| Slash command            | What it does                                                          |
|--------------------------|-----------------------------------------------------------------------|
| `/trai:status`            | Overlay path, size, number of changed files.                          |
| `/trai:diff`              | Filtered list of files added / modified / deleted in the overlay.     |
| `/trai:commit`            | Apply the overlay to the real FS. **Destructive.** Run diff first.    |
| `/trai:discard --yes`     | Remove the overlay. Requires explicit `--yes`.                         |
| `/trai:explore`           | Print the shell command to open an interactive shell inside overlay.  |
| `/trai:doctor`            | Run preflight; print remediation for any failing check.               |
| `/trai:passthrough`       | One-shot bypass: next Bash command runs outside `try`.                 |

A typical session:

```
/trai:status
...work with Claude: installs, builds, migrations...
/trai:diff
/trai:commit
```

Or, if things went sideways:

```
/trai:discard --yes
```

---

## Configuration

User overrides live at `${CLAUDE_PLUGIN_DATA}/config.json`. The shape matches
[`config/defaults.json`](config/defaults.json). Common overrides:

```json
{
  "passthrough": ["git *", "ls *", "my-internal-tool *"],
  "warnOnPassthrough": false
}
```

Providing an array replaces the default for that key entirely (not element-wise).

---

## Repository layout

```
.claude-plugin/   plugin + marketplace manifests
hooks/            session-start, pre-bash rewriter, session-end
scripts/          doctor, passthrough matcher, filter, slash-command backers
commands/         slash-command definitions
config/           default passthrough + ignore lists
docs/             user-facing docs: limitations, use cases
docs/claude/      internal research notes and design rationale
test/             end-to-end smoke test
vendor/try/       binpash/try as a pinned submodule (fallback binary)
```

User-facing docs:

- [`docs/limitations.md`](docs/limitations.md) — full known-issue list with workarounds.
- [`docs/use-cases.md`](docs/use-cases.md) — concrete examples of trai behavior.

Internal / contributor docs (design rationale, research notes):

- [`docs/claude/research-try.md`](docs/claude/research-try.md) — how `try` works, its limits.
- [`docs/claude/research-claude-code.md`](docs/claude/research-claude-code.md) — Claude Code hooks, plugins, marketplaces.
- [`docs/claude/research-review-ux.md`](docs/claude/research-review-ux.md) — post-hoc review design landscape.
- [`docs/claude/design-notes.md`](docs/claude/design-notes.md) — the locked-in decisions and why.

The implementation plan approved during design lives at
`/scratch/<user>/.claude/plans/the-goal-of-this-hashed-flask.md` on the
development host.

---

## Testing

```sh
./test/smoke.sh
```

Runs eleven end-to-end checks against the hook pipeline in an isolated temp
directory. Does NOT run inside the repo cwd (the test commits and discards
overlays, which would interfere with work in progress).

---

## Loud warnings

1. **Edit / Write / MultiEdit are NOT sandboxed.** Use git.
2. **Not a security sandbox.** Network traffic is unrestricted.
3. **`/trai:commit` is destructive.** Run `/trai:diff` first.
4. **Long-running daemons** (`npm run dev &`) shouldn't be wrapped; add them to
   the passthrough list.
5. **`try` is prototype-quality.** Upstream has ~30 open issues around edge
   cases; expect quirks on exotic filesystems (NFS `$HOME`, btrfs subvolumes,
   Docker-in-Docker). Run `/trai:doctor` if things misbehave.

## License

MIT. See [`LICENSE`](LICENSE).

## Acknowledgments

The first version of this plugin was implemented by [Guy Van den Broeck](https://web.cs.ucla.edu/~guyvdb/) after a discussion over lunch.

