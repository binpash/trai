# trai use cases

Concrete examples of trai behavior across common and edge-case scenarios.
Each section describes what to expect and why — useful for understanding the
plugin before relying on it in a real workflow.

---

## UC1 — Empty overlay: graceful no-op commands

When a session has no pending changes, all review commands handle it cleanly.

```
/trai:diff    → "trai: no filesystem changes in the current overlay."
/trai:commit  → "trai: overlay is empty; nothing to commit. Session remains active."
/trai:discard --yes → "trai: discarded. Session cleared."
```

**Why this matters.** It's safe to run `/trai:diff` or `/trai:commit` at any
point without knowing whether anything changed. None of these exit non-zero on
an empty overlay.

---

## UC2 — Basic create → diff → commit

The core workflow: a sandboxed Bash command creates a file, you inspect it,
then apply it.

```bash
echo "hello" > myproject/hello.txt   # sandboxed — goes into overlay
```

```
/trai:diff
  myproject/hello.txt (added)

/trai:commit
  trai: committing 1 change(s) ...
  trai: commit complete. Clearing session.
  trai: new sandbox started at .../overlay
```

After commit, `myproject/hello.txt` is on the real filesystem and a fresh
overlay begins automatically — subsequent Bash commands continue to be
sandboxed without any action from the user.

**Note on ignored paths.** Changes to paths in the ignore list (e.g. `/tmp`,
`~/.claude`, `~/.cache`) are excluded from both the diff count and the commit.
If you work in a directory that happens to be ignored, override the list in
`${CLAUDE_PLUGIN_DATA}/config.json`.

---

## UC3 — Multi-step stateful operations

Sequential Bash calls share one overlay, so each call sees the state left by
the previous ones.

```bash
mkdir -p myapp/src                        # call 1 — overlay sees new dir
echo "requests" > myapp/requirements.txt  # call 2 — overlay already has myapp/
echo "import requests" > myapp/src/main.py # call 3 — overlay has myapp/src/
```

```
/trai:diff
  myapp/requirements.txt (added)
  myapp/src/main.py (added)
  myapp/src/ (added)
  myapp/ (added)

/trai:commit  → all four entries land on the real filesystem at once
```

**Why this works.** All three calls reuse the same `upperdir` under
`$XDG_STATE_HOME/trai/sessions/<id>/overlay/`. From the perspective of each
sandboxed command, the filesystem looks like the real FS plus everything prior
calls wrote. The real FS is unchanged until `/trai:commit`.

---

## UC4 — Discard safety net

The primary use case: let Claude make potentially destructive changes, inspect
them, and throw them away if they look wrong.

Suppose two important files already exist on the real filesystem:

```
/home/user/project/logs/app.log
/home/user/project/config.json
```

Claude runs a cleanup:

```bash
rm /home/user/project/logs/app.log
rm /home/user/project/config.json
```

Both deletions go into the overlay as whiteout entries. The real files are
untouched.

```
/trai:diff
  /home/user/project/logs/app.log (deleted)
  /home/user/project/config.json (deleted)
```

After reviewing: the deletions look too aggressive.

```
/trai:discard --yes
  trai: discarded. Session cleared.
```

Both files are still on the real filesystem, unchanged.

**Note on the `--yes` flag.** `/trai:discard` requires explicit `--yes` to
prevent accidental data loss. Calling it without the flag prints usage and
exits non-zero.

---

## UC5 — Multiple commit cycles

A session is not limited to one commit. After each `/trai:commit`, trai
automatically starts a fresh overlay so subsequent Bash commands are still
sandboxed.

```bash
echo "cycle1" > work/file1.txt
```
```
/trai:commit
  trai: committing 1 change(s) ...
  trai: new sandbox started at .../sessions/20260501T120000Z-1234/overlay
```

```bash
echo "cycle2" > work/file2.txt   # goes into the NEW overlay
```

```
/trai:diff
  work/file2.txt (added)         # only file2 — file1 is already committed
```

```
/trai:commit
  trai: committing 1 change(s) ...
```

Both `file1.txt` and `file2.txt` now exist on the real filesystem. This lets
you batch related changes per commit without stopping the sandboxing.

---

## UC6 — Passthrough boundary: compound commands

Commands that are passthrough-listed (e.g. `git`, `grep`, `ls`) run directly
on the real filesystem. **However, any command containing shell metacharacters
(`&&`, `||`, `|`, `;`, `>`, `<`, `$()`, backtick, `&`) is always sandboxed,
even if it starts with a passthrough-listed name.**

```bash
git status          # passthrough — reads real repo, no overlay
git log --oneline   # passthrough
```

```bash
git log | head -5 > recent.txt   # SANDBOXED — contains | and >
echo done && touch marker.txt    # SANDBOXED — contains &&
grep -r foo . > results.txt      # SANDBOXED — contains >
```

After the three compound commands:

```
/trai:diff
  recent.txt (added)
  marker.txt (added)
  results.txt (added)
```

None of them exist on the real filesystem yet. `/trai:discard --yes` removes
them all without a trace.

**Why this rule exists.** A compound command like `git log | tee /etc/hosts`
starts with `git` (passthrough-listed) but has a destructive side effect.
The metacharacter guard prevents passthrough-listed prefixes from being used
as a Trojan horse.

---

## UC7 — One-shot passthrough

`/trai:passthrough` sets a single-use bypass token: the **next** Bash command
Claude runs will go directly to the real filesystem instead of the overlay.
The token is consumed after one use.

```
/trai:passthrough
  trai: next Bash command will bypass the try sandbox (one-shot).
```

```bash
echo "DB_URL=postgres://localhost/dev" > .env   # bypass active → real FS
```

The `.env` file is immediately on the real filesystem and will **not** appear
in `/trai:diff`.

```bash
echo "another change" > notes.txt   # bypass consumed → sandboxed again
```

```
/trai:diff
  notes.txt (added)          # only this one — .env is already real
```

**Important prerequisite.** The bypass command runs on the real filesystem.
If the target directory was only created inside the overlay (via a prior
sandboxed `mkdir`), the bypass command will fail with "No such file or
directory" — the real FS doesn't know about overlay-only directories. Create
the directory with the `Write` tool or commit the `mkdir` first.

**Use this sparingly.** The point of trai is to defer writes until reviewed.
`/trai:passthrough` is for the occasional command that must land immediately
(e.g., a credential file, a git commit, a socket that requires the real path).

---

## UC8 — Modifying an existing file

When Claude overwrites a file that already exists on the real filesystem, the
overlay captures only the new version. The original is untouched until commit.

```bash
cat myproject/config.txt       # passthrough — shows "version=1" from real FS
echo "version=2" > myproject/config.txt   # sandboxed — stored in overlay
cat myproject/config.txt       # passthrough — still shows "version=1"
```

```
/trai:diff
  myproject/config.txt (modified)
```

```
/trai:commit
  trai: committing 1 change(s) ...

cat myproject/config.txt       # now shows "version=2"
```

**Why `cat` shows the old value after the write.** `cat` is on the
passthrough list, so it reads the real filesystem directly, bypassing the
overlay. Only sandboxed commands see the overlay's version. This is the
correct behaviour: it lets you verify that the overlay is truly isolated
from the live filesystem before committing.

---

## UC9 — Symlinks and directory creation

trai tracks not just file additions and modifications but also directory
creation and symlink creation as distinct entry types.

```bash
mkdir -p myproject/bin
echo "#!/bin/sh" > myproject/bin/run.sh
ln -s myproject/bin/run.sh myproject/run
```

```
/trai:diff
  myproject/bin (created dir)
  myproject/bin/run.sh (added)
  myproject/run (symlink)
```

All three entry types are counted in `/trai:status` and `/trai:diff`.
After commit, the symlink is preserved on the real filesystem with its
original target path intact.

**Edge case: symlink-only overlay.** If the overlay contains only
`(created dir)` or `(symlink)` entries and no plain `(added)` files,
`/trai:commit` still applies them correctly — they are not
skipped as "nothing to commit".

---

## UC10 — Status and diff counts agree

`/trai:status` reports a `changed files` count that always matches the
number of entries shown by `/trai:diff`. Both counts include all entry
types: `(added)`, `(modified)`, `(deleted)`, `(created dir)`, and
`(symlink)`.

```bash
mkdir -p work
echo a > work/a.txt
echo b > work/b.txt
echo c > work/c.txt
echo d > work/d.txt
echo e > work/e.txt
```

```
/trai:status
  changed files: 6      ← 1 directory + 5 files

/trai:diff
  work (created dir)
  work/a.txt (added)
  work/b.txt (added)
  work/c.txt (added)
  work/d.txt (added)
  work/e.txt (added)    ← 6 entries total
```

The two numbers agree. Use `/trai:status` for a quick summary and
`/trai:diff` when you need to see exactly which paths changed.
