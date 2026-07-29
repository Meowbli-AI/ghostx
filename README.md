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

After a session has been bound once, restoration is deterministic even when
many Codex sessions share the same working directory.

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
3. Appends Ghostx `SessionStart` and `UserPromptSubmit` groups to
   `~/.codex/hooks.json` without replacing existing hooks.
4. Adds one marked source block to `~/.zshrc`.
5. Removes obsolete title-probe helpers from earlier Ghostx installations.

After the first install, open `/hooks` once and trust the Ghostx hooks if they
are pending review. New and resumed Codex sessions bind at `SessionStart`.
Sessions that were already running bind progressively on their next prompt.
No `exec zsh`, new chat, or resume cycle is required.

Binding is deliberately best-effort. If Ghostty is not focused, its working
directory does not match, or AppleScript is temporarily unavailable, the hook
exits successfully and retries on the next prompt. It has a shorter internal
deadline than Codex's hook timeout, so a failed save must not block a prompt.
If that deadline interrupts a write after its lock is created, later hooks
automatically reclaim the stale lock and resume progressive saves.

On the next Ghostty relaunch, restored surfaces automatically receive their
exact `codex resume <UUID>` command. Ghostx disables Codex's startup update
check for these automatic resume commands only. Otherwise, choosing **Update
now** exits before Codex processes the session UUID and leaves the terminal at
the shell prompt. Normal manual Codex launches still check for updates, and
`codex update` remains available at any time.

A Mac reboot is not required for an end-to-end check. After the desired
sessions have each received at least one prompt, save active terminal work,
fully quit Ghostty, and reopen it. Quitting Ghostty terminates the processes in
its surfaces.

Closing every window is not the same as quitting the application. For a strict
test, record the process ID before quitting:

```sh
pgrep -x ghostty
```

After Quit, the command should return no process. Reopening Ghostty should
produce a new process ID. Ghostx performs restoration once for that new Ghostty
process.

## How binding works

On a normal start or prompt, the Codex hook asks Ghostty for its focused
terminal and accepts it only when Ghostty's reported working directory matches
the hook's current working directory. It never changes the terminal title.
During restoration, Ghostx injects the known surface UUID into the exact
`codex resume` command, so restored sessions do not depend on focus. The
mapping is stored at:

```text
${XDG_STATE_HOME:-~/.local/state}/ghostx/state.json
```

The restore helper runs once per Ghostty application process. It waits for the
restored surface list to settle, then targets only surface UUIDs that exist in
both the live Ghostty application and the state file. Ghostx does not recreate
a surface that Ghostty itself did not restore, because the same missing surface
can also mean that the user intentionally closed it.

macOS asks for Automation permission the first time the hook controls Ghostty.

Ghostx versions before the focused-terminal implementation briefly used
terminal-title probes. Upgrading removes those helpers and prevents further
title changes. A title already left behind by an older version may remain until
the shell or terminal resets it; Ghostx cannot reconstruct the previous title.

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
