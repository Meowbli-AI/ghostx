# ghostx

Restore the exact coding-agent session in every terminal after a reboot.

Ghostx is a small configuration integration, not a terminal multiplexer and
not a daily-use CLI. The first release connects three native persistence
mechanisms:

- Ghostty restores windows, tabs, splits, working directories, and stable
  terminal-surface UUIDs.
- Codex lifecycle hooks expose the exact session UUID on session start and on
  the next prompt in an already-running session.
- zsh starts a one-shot restore helper when a restored Ghostty process opens
  its shells.

The result is deterministic even when many Codex sessions share the same
working directory.

```text
Ghostty surface UUID <-> Codex session UUID
          |                    |
          +---- local state ---+
                    |
              reboot / relaunch
                    |
        Ghostty restores the same surface UUID
                    |
          codex resume <exact-session-uuid>
```

## Status

The initial adapter set is intentionally narrow:

- macOS
- Ghostty 1.3 or newer
- Codex CLI hooks
- zsh

There is no daemon, tmux dependency, cloud service, analytics, or telemetry.
Ghostx stores only terminal UUIDs, agent type, session UUIDs, and timestamps.
It never reads transcript contents.

## Install

Clone the repository and run:

```sh
./install.sh
```

The installer is idempotent and preserves existing configuration. It:

1. Copies the runtime integration to
   `${XDG_DATA_HOME:-~/.local/share}/ghostx/runtime`.
2. Appends a marked `window-save-state = always` block to the Ghostty config.
3. Appends one `SessionStart` group to `~/.codex/hooks.json` without replacing
   existing hooks.
4. Adds one marked source block to `~/.zshrc`.
5. Backfills already-running Codex TUI processes by matching each process's
   open rollout filename and controlling TTY to its Ghostty surface.

The surface identity is normally exported during interactive shell startup.
After the first install, open `/hooks` once and trust the Ghostx hooks if they
are pending review. New and resumed Codex sessions bind at `SessionStart`.
Sessions that were already running are backfilled during installation. The
installer reads only the rollout filename already opened by each Codex process,
not transcript contents, and matches its controlling TTY to the Ghostty
surface. The prompt hook remains a progressive fallback; if a Codex process
predates the shell integration, it resolves the current Ghostty surface directly
from that TTY. No `exec zsh`, new chat, or resume cycle is required.

On the next Ghostty relaunch, restored surfaces automatically receive their
exact `codex resume <UUID>` command.

A Mac reboot is not required for an end-to-end check. After at least one
session has been bound, fully quit Ghostty and reopen it; this exercises the
same application-state restoration path. Save active terminal work first,
because quitting Ghostty terminates the processes running in its surfaces.

## How binding works

At interactive shell startup, the zsh integration temporarily sets a unique
terminal title through `/dev/tty`, resolves that title to Ghostty's stable
terminal UUID through AppleScript, immediately restores the previous title,
and exports the UUID as `GHOSTX_SURFACE_ID`. The Codex hooks receive
`session_id` on stdin and combine it with that exported surface identity. If an
older Codex process does not have the environment variable, the hook performs
the same TTY lookup itself. The mapping is stored at:

```text
${XDG_STATE_HOME:-~/.local/state}/ghostx/state.json
```

The restore helper runs once per Ghostty application process. It waits for the
restored surface list to settle, then targets only surface UUIDs that exist in
both the live Ghostty application and the state file.

macOS asks for Automation permission the first time the hook controls Ghostty.

## Uninstall

```sh
./uninstall.sh
```

Uninstall removes only marked Ghostx configuration and the Ghostx hook group.
It does not delete state by default. Remove the state explicitly if desired:

```sh
rm -r "${XDG_STATE_HOME:-$HOME/.local/state}/ghostx"
```

## Configuration snippets

The generated integration is based on the readable snippets in [`config/`](config/).
They are provided for people who prefer manual installation.

## Design boundary

Ghostx restores identity and startup intent. It cannot resurrect an operating
system process, in-flight command output, or unsaved application memory.
Workspace files and Codex transcripts remain owned by their original tools.

Future terminal, agent, and shell support should stay adapter-shaped:

```text
adapters/
  terminals/ghostty
  agents/codex
  shells/zsh
```

An optional diagnostics command may be useful later, but the automatic path
must remain configuration-first.

## Development

Run the isolated tests on macOS:

```sh
./tests/test.sh
```

The tests use temporary homes and a mock AppleScript runner. They do not type
into live terminals or modify real user configuration.
