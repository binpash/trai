# trai — Claude orientation guide

trai sandboxes every `Bash` tool call through overlayfs so changes accumulate
in a staging area until the user runs `/trai:commit` or `/trai:discard --yes`.

---

## What is and isn't sandboxed

| Surface | Sandboxed? |
|---------|-----------|
| `Bash` tool calls | **Yes** — written to overlay, not real FS |
| `Edit` / `Write` / `MultiEdit` tools | **No** — write directly to real FS immediately |
| `git`, `sudo`, `docker`, read-only commands (`ls`, `cat`, `grep`, …) | **No** — passthrough list, run on real FS |
| Commands starting with `$CLAUDE_PLUGIN_ROOT/` | **No** — plugin internals self-exempt |
| Commands containing `&&`, `||`, `;`, `|`, `&` | **Yes** — compound-command guard always sandboxes |

Passthrough commands that *read* the filesystem (e.g. `cat file.txt`) see the
**real FS**, not the overlay. Changes written by sandboxed Bash calls are
invisible to passthrough reads until `/trai:commit` is run.

---

## Slash commands and their output

| Command | What it does |
|---------|-------------|
| `/trai:status` | Overlay path, disk size, count of changed entries |
| `/trai:diff` | Filtered list of overlay changes (format below) |
| `/trai:commit` | Applies overlay to real FS — destructive, no undo |
| `/trai:discard --yes` | Deletes overlay; `--yes` is required |
| `/trai:passthrough` | One-shot bypass: the *next* Bash call runs on real FS |
| `/trai:explore` | Prints a shell command to open an interactive shell inside the overlay (paste in a separate terminal) |
| `/trai:doctor` | Preflight check; prints remediation if something is broken |

### `/trai:diff` output format

Each changed entry looks like:

```
/path/to/file (added)
/path/to/file (modified)
/path/to/file (deleted)
/path/to/dir  (created dir)
/path/to/link (symlink)
```

"No changes in overlay" means the session is empty or every change is in an
ignored path (e.g. `/tmp`). This is normal — not an error.

---

## Gotchas to keep in mind

**Reads lag behind writes.** After a sandboxed `echo foo > file.txt`, running
`cat file.txt` (passthrough) still shows the old content. The write is in the
overlay. To verify a sandboxed write, use `/trai:diff` or `/trai:explore`.

**`2>&1` is sandboxed.** The `&` character triggers the compound-command guard,
so `ls /path 2>&1` runs inside `try`. Unexpected but intentional.

**`&&`-chained git commands are sandboxed.** Never chain `git` with `&&`. Run
each git command as a separate `Bash` call, or use a temp file for multi-step
git workflows.

**Commit messages must not use `<`, `>`, or `$(...)`** in inline shell strings
— shell redirection and command substitution in commit messages interact badly
with the sandbox. Write the message to a file with `Write`, then commit with
`git commit -F /tmp/msg.txt`.

**After `/trai:commit` a fresh overlay starts automatically.** The session
pointer is cleared and the next `Bash` call begins a new empty overlay.

**`/trai:passthrough` bypass is consumed after one use.** The token is written
to the real FS, so it works correctly even though the current session is active.
Overlay-only files are not visible to the bypassed command.

**Edit/Write/MultiEdit are never in the diff.** If the user asks why a file
change doesn't appear in `/trai:diff`, the answer is that it was an Edit/Write
tool call — those go straight to disk. Tell the user to use `git diff` for
those.
