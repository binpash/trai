# Claude Code extension surfaces — research notes

Captured 2026-04-23. This is the reference we need to build a plugin that intercepts every `Bash` tool call and wraps it in `try`.

## The four surfaces, and which one we're actually using

| Surface | What it is | Can intercept Bash? | Can mutate tool input? | Right for us? |
|---|---|---|---|---|
| **Hooks** | Shell / HTTP / MCP / prompt handlers fired at lifecycle events (`PreToolUse`, `PostToolUse`, `SessionStart`, `SessionEnd`, …) | Yes (`PreToolUse` with `matcher: "Bash"`) | **Yes**, since v2.0.10 via `hookSpecificOutput.updatedInput` | **This is the primitive we use.** |
| **Skills** | Markdown + optional scripts auto-invoked by Claude based on a `description` field | No | No | Wrong tool. Skills add *context*, not interception. |
| **Slash commands** | Markdown files under `commands/` that the user types (`/foo`) | No — user-triggered only | No | We ship seven slash commands for *review ergonomics*, not interception. |
| **Plugins** | A bundle containing any of the above + a manifest, distributed via a marketplace | Via bundled hooks | Via bundled hooks | **Our distribution format.** A plugin wrapping a single `PreToolUse` hook and seven slash commands is exactly what we ship. |
| **MCP servers** | JSON-RPC tool providers | No (they *expose* tools, not intercept) | No | Wrong primitive. Don't confuse "MCP server" with "Bash wrapper." |
| **OS sandbox** (bubblewrap/Seatbelt) | Claude Code's built-in sandbox (Oct 2025 release) | OS-level, all subprocess | No — block only | Overlaps in spirit but gives no post-hoc diff. Our plugin is an alternative. |

## Hook mechanics — the parts we care about

### Configuration shape (`hooks/hooks.json` inside a plugin)

The event map must be wrapped under a top-level `"hooks"` key. Omitting this wrapper produces a cryptic load error:

```
Hook load failed: [{"expected":"record","code":"invalid_type",
                    "path":["hooks"],"message":"Invalid input: expected record, received undefined"}]
```

We ate one debugging round on that. The shape is the same as `settings.json`'s `hooks` section:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh",
            "timeout": 5 }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/pre-bash.sh",
            "timeout": 5 }
        ]
      }
    ],
    "SessionEnd": [
      { "matcher": "*",
        "hooks": [
          { "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-end.sh",
            "timeout": 5 } ] }
    ]
  }
}
```

`matcher` grammar: `"*"` or empty means match everything. Alphanumeric + `|` means exact string or alternation (`"Bash"`, `"Edit|Write"`). Other characters are interpreted as regex. Fine-grained Bash specifiers like `Bash(rm *)` are supported but we don't use them — we do the rewriting ourselves in the shell script, after reading `tool_input.command`, so that logic is testable without going through Claude.

### `SessionStart` fires more than once per Claude session

Counterintuitive but important: `SessionStart` fires on **`startup`, `resume`, `clear`, and `compact`** (including auto-compact). If your handler unconditionally creates fresh per-session state, every `/compact` orphans the previous overlay and the plugin appears to "lose" state mid-session.

Our `session-start.sh` is idempotent as a result: if `current-session` already points at an existing overlay dir, we reuse it and emit a `"resumed"` banner. New sessions are only created when there's nothing live to resume. See `docs/design-notes.md` §"Why SessionStart is idempotent."

### `PreToolUse` hook stdin — what Claude gives us

```json
{
  "session_id": "abc123",
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_input": { "command": "npm test", "description": "run tests" },
  "tool_use_id": "toolu_01ABC123",
  "permission_mode": "default",
  "cwd": "/path/to/project"
}
```

### `PreToolUse` hook stdout — the contract

Exit `0` with JSON on stdout:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "sandboxed via try",
    "updatedInput": {
      "command": "try -D '/path/to/overlay' bash -c 'npm test'"
    },
    "additionalContext": "trai: sandboxed into /path/to/overlay"
  }
}
```

Key fields:

- **`updatedInput`** — the load-bearing field. Claude uses this rewritten input instead of the original. This is what makes per-Bash-call sandboxing possible.
- **`permissionDecision`** — `"allow"` skips the normal permission prompt, `"ask"` forces it, `"deny"` blocks. We return `"allow"` because we rewrote the command into something safer; the user can still see the rewrite in the UI.
- **`additionalContext`** — a string appended to Claude's context window. Useful for "hey, this was sandboxed" notes.

Exit `2` blocks the tool and sends stderr to Claude. We don't use exit-2 — v1 rewrites or passes through, never denies.

Other exit codes are non-blocking warnings.

### Important caveats

- **Multiple hooks racing.** If two plugins both register a `PreToolUse(Bash)` hook and both return `updatedInput`, the *last to finish* wins. Non-deterministic. We document: don't stack trai with another Bash mutator.
- **Hooks run as the invoking user.** No sandbox on the hook itself. A malicious hook is game-over. Users who install our plugin are trusting us the same way they trust any shell script on their `$PATH`.
- **Hook timeout** defaults to 60s, we cap at 5s. Long hooks block Claude and hurt UX.
- **Env vars Claude provides to command hooks:**
  - `CLAUDE_PROJECT_DIR` — abs path to project root (useful for `git rev-parse HEAD`).
  - `CLAUDE_PLUGIN_ROOT` — abs path to our plugin's install dir.
  - `CLAUDE_PLUGIN_DATA` — abs path to our plugin's persistent data dir (survives across sessions). We write `current-session` there.

### Hook types beyond `command`

- `http` — POST to a URL with the same JSON body. Useful for centralized policy enforcement (security team runs a server). Not relevant to us.
- `mcp_tool` — call a registered MCP server tool. More latency. Not relevant.
- `prompt` — a one-shot LLM call. Expensive. Not relevant.
- `agent` — spawn a subagent. Expensive. Not relevant.

We stick to `command` (plain shell script) for simplicity and speed.

## Plugin packaging

### Minimum manifest (`.claude-plugin/plugin.json`)

```json
{
  "name": "trai",
  "version": "0.1.0",
  "description": "Sandbox every Bash tool call through binpash/try, review after.",
  "author": { "name": "...", "email": "..." },
  "homepage": "https://github.com/.../trai",
  "license": "MIT",
  "keywords": ["sandbox", "try", "overlayfs", "review"]
}
```

Claude Code discovers `hooks/hooks.json`, `commands/*.md`, and `scripts/` by convention from the plugin root.

### Marketplace manifest (`.claude-plugin/marketplace.json`)

A marketplace is a JSON file listing one or more plugins installable from a Git URL. A single-plugin marketplace is valid:

```json
{
  "name": "trai-marketplace",
  "owner": "<your-username>",
  "plugins": [
    {
      "name": "trai",
      "source": "./",
      "description": "Post-hoc review sandbox via binpash/try."
    }
  ]
}
```

Users install with:

```bash
/plugin marketplace add https://github.com/UCLA-StarAI/trai
/plugin install trai@trai-marketplace
```

### Permissions and settings we do **not** change

We don't write to the user's `settings.json`. Everything the plugin needs lives in `${CLAUDE_PLUGIN_DATA}`. Respecting the user's existing permission rules (`allow` / `ask` / `deny`) is important: a user who has denied `Bash(rm -rf *)` still gets that denial even after our rewrite, because the rewritten command is what gets evaluated.

## Prior art — integrations that inspired or constrain us

- **anthropic-experimental/sandbox-runtime** — the bubblewrap/Seatbelt wrapper used by Claude Code's built-in sandbox. Wraps the *whole session*, not per-call; blocks rather than reviews. <https://github.com/anthropic-experimental/sandbox-runtime>
- **CaptainMcCrank/SandboxedClaudeCode** — community wrapper using firejail/bubblewrap. Outer-shell approach, not hook-based.
- **matgawin/bubblewrap-claude** — Nix flake launching Claude inside bwrap.
- **dvcrn/mcp-server-subagent** — MCP server delegating to subagents. Different axis (delegation not interception) but illustrates the MCP-vs-hook boundary well.

None of these do per-Bash-call interception with `updatedInput` rewriting, nor post-hoc review. That's the niche we fill.

## What we deliberately **do not** use

- **`permissions.deny`** for Bash patterns. Deny rules fire *before* our hook, so if a user has `"deny": ["Bash(rm -rf *)"]` that denial still stands (good). But we don't add our own deny rules — our value is *wrapping*, not *blocking*.
- **`PostToolUse` blocking.** We could look at Bash output and block on suspicious changes. Too noisy; defer to v2.
- **Custom MCP server.** Tempting for exposing "overlay state" as a resource, but adds a subprocess and JSON-RPC round-trip per query. Slash commands shelling out to `try summary` are fine.
- **Skills.** A skill that activates on "risky install" is cute but confusing; users should *always* know if interception is active, not have it toggled by Claude's opinion of the prompt.

## Reference links

- Hooks reference: <https://code.claude.com/docs/en/hooks>
- Sandboxing: <https://code.claude.com/docs/en/sandboxing>
- Permissions: <https://code.claude.com/docs/en/permissions>
- Skills: <https://code.claude.com/docs/en/skills>
- Plugin marketplaces: <https://code.claude.com/docs/en/plugin-marketplaces>
- MCP: <https://code.claude.com/docs/en/mcp>
- Sandbox runtime (OSS): <https://github.com/anthropic-experimental/sandbox-runtime>
- Official plugin marketplace: <https://github.com/anthropics/claude-plugins-official>
