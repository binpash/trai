# Post-hoc review UX — research notes

Captured 2026-04-23. Context for why our review flow looks the way it does, and for the things we *explicitly don't* do.

## Landscape of "let the user review before committing" in AI coding tools

| Tool | Review granularity | Sandbox? | Undo path |
|---|---|---|---|
| **Cursor** (agent mode) | Inline diff, per-hunk accept / reject | No (local FS) | Reject a hunk; or revert via git |
| **Aider** | One git commit per AI turn | No | `/undo` reverts last commit; full git workflow thereafter |
| **Cline / Roo Code** | Per-action approval + configurable auto-approve ("YOLO") | No | Reject before applying; otherwise git |
| **Devin Review** | PR-level diff analysis w/ bug categorization | Cloud VM | GitHub PR flow |
| **OpenAI Codex CLI** | Approval modes (suggest / auto-edit / full-auto) | Optional sandbox | Approve/reject per-action |
| **Claude Code** today | Plan mode, `/diff`, auto-accept, ultrareview | Bubblewrap / Seatbelt (blocks, no diff) | Reject before applying or use git |

The ones closest to our model are Aider (commit-then-undo via git — but no filesystem sandbox) and the Claude Code built-in sandbox (filesystem sandbox but no diff-and-review — it blocks).

**Nobody in this list combines "fine-grained interception of each Bash call" with "session-level post-hoc diff review."** That's the gap `trai` fills.

## Non-AI prior art that shaped our design

- **`try` (binpash)** — the direct ancestor. Overlayfs + commit-or-discard prompt. We're literally building on it.
- **Docker overlay2 storage driver** — the canonical demo that overlay-based diffs are inspectable *as plain files*, not through a proprietary API. The docker filesystem-layer model is why we think overlays are reviewable.
- **git's interactive staging** (`git add -p`, `git stash --patch`) — the UX gold standard for per-hunk acceptance. Deliberately **not** what we ship in v1; we defer partial commits to git itself (after we commit the overlay).
- **NixOS / Guix build sandboxes** — show that ephemeral sandboxes are normal; they GC overlays routinely. Shapes our thinking on overlay lifetime (keep for later, discard on request, doctor warns on disk pressure).
- **`checkinstall`** — an obscure 2000s Debian tool that records what `make install` adds to a system. Same shape, no overlay — captures via `strace`. Proves the problem is old.

## Design tensions — the ones we felt

### 1. Per-call review vs session review

Intercepting per Bash call (what we do) naturally suggests per-call review. But per-call review is noisy — a session with 50 `Bash` calls produces 50 prompts. Cursor and Roo show that per-action approval scales poorly.

We took the middle path: interception is per-call, review is per-session. The overlay is shared across calls so we can do one final review of the accumulated diff. Users who want mid-session feedback run `/trai:diff` whenever they feel like it.

### 2. Partial acceptance is hard

Git can do per-hunk. Most AI tools show file-level-or-nothing. A real per-file picker for an overlay means:

- A TUI (ncurses or equivalent) or a browser-based diff viewer.
- Handling rename/move/delete tombstones coherently.
- Synthesizing a partial commit by `cp --reflink=auto`-ing only accepted paths instead of calling `try commit`.
- Reconciling modifications that overlap (a `.env` file modified twice across overlay and real FS since session start).

We cut this from v1. After `/trai:commit` the changes land in the real tree and `git add -p` is right there. Users without git lose out; documented.

### 3. Side effects aren't in the diff

The agent runs `curl api.example.com` and exfiltrates data. Commits to a git remote inside the overlay. Pipes a password to a third-party API. The filesystem diff shows **none** of these. This is a fundamental limit of post-hoc FS review: it shows *consequences for the filesystem*, not *actions the agent took*.

We state this loudly in `README.md` and `docs/limitations.md`. The honest framing:

> `trai` is a correctness-review tool. It is not a security boundary. If you don't trust the agent to have network access and credentials, don't give it those — no review flow will save you.

### 4. "Commit" can merge-conflict with the real tree

User starts a long Claude session. Meanwhile they edit `src/foo.ts` in another window. At commit time, overlay's `src/foo.ts` overwrites the new live version. `try commit` has no merge intelligence.

Mitigations:
- `/trai:status` shows overlay age; if it's been hours since session start, user is warned.
- Passthrough list keeps `git` outside the overlay so manual commits during the session don't collide.
- For the overlap scenario proper, we document: work in git, commit real-tree work before overlay commit.

We do *not* try to be smarter than `try commit`. If the upstream tool gains merge semantics we inherit them.

### 5. Auto-approve is a trap

Cline's YOLO and Roo's configurable auto-approve exist because users want speed. If we add auto-approve, we own the incidents. In v1 every commit is explicit (`/trai:commit`). A `/trai:commit --yes` non-interactive variant exists for scripting/smoke tests only; it's not the default UX.

## Unsolved-by-design (v1)

1. **Partial commit** — defer to git post-commit.
2. **Exfiltration blocking** — not a goal; document limit.
3. **Network isolation** — `try -x` severs the Anthropic API; not default.
4. **Edit/Write/MultiEdit sandboxing** — hooks can't cleanly wrap Node-level writes.
5. **Mid-session checkpointing without committing** — `/trai:commit-now` is a v2 idea.
6. **Multi-session concurrency** — one overlay per Claude session, enforced via lockfile.
7. **Auto-commit policy** ("auto-commit if only `docs/**` changed") — deferred; invites foot-guns.

## Framing we use in docs and UI

- **"Sandbox"** — used carefully. We say "overlay sandbox" or "post-hoc review sandbox." We never claim "security sandbox."
- **"Reversible"** — accurate for Bash-subprocess side effects. We say "reversible shell commands, non-reversible code edits."
- **"Commit"** — we use this word. It's overloaded with git but in the `try` context means "apply overlay changes to live FS." Slash commands and banners always qualify: `try-commit (apply overlay to real FS)`.
- **"Review"** — the primary user-facing verb. `/trai:diff` is the review action. Commit is the consequence of a review.

## Sources

- Cursor agent: <https://www.amplifilabs.com/post/cursor-agent-inside-the-ai-powered-workflow-engine-for-developers>
- Aider git flow: <https://aider.chat/docs/git.html>
- Devin Review: <https://docs.devin.ai/work-with-devin/devin-review>
- Roo auto-approve: <https://docs.roocode.com/features/auto-approving-actions>
- Cline auto-approve: <https://docs.cline.bot/features/auto-approve>
- Claude Code sandboxing (engineering post): <https://www.anthropic.com/engineering/claude-code-sandboxing>
- Docker overlay2 driver: <https://docs.docker.com/engine/storage/drivers/overlayfs-driver/>
- OWASP AI agent security cheat sheet: <https://cheatsheetseries.owasp.org/cheatsheets/AI_Agent_Security_Cheat_Sheet.html>
