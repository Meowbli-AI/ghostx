#!/bin/sh

set -eu
umask 077

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
data_home=${XDG_DATA_HOME:-"$HOME/.local/share"}
runtime_dir="$data_home/ghostx/runtime"
codex_dir=${CODEX_HOME:-"$HOME/.codex"}
hooks_file="$codex_dir/hooks.json"
state_dir=${GHOSTX_STATE_DIR:-"${XDG_STATE_HOME:-$HOME/.local/state}/ghostx"}
zshrc=${ZDOTDIR:-$HOME}/.zshrc
ghostty_config=${GHOSTX_GHOSTTY_CONFIG:-"$HOME/Library/Application Support/com.mitchellh.ghostty/config"}

ghostty_instance_id() {
  identity=""
  ghostty_pids=$(
    ps -axo pid=,command= 2>/dev/null |
      awk '$2 ~ /\/Ghostty\.app\/Contents\/MacOS\/ghostty$/ { print $1 }' |
      sort -n
  )
  for ghostty_pid in $ghostty_pids; do
    started_at=$(ps -o lstart= -p "$ghostty_pid" 2>/dev/null || true)
    identity="${identity}${ghostty_pid}-${started_at}-"
  done
  printf '%s' "$identity" | tr -cd 'A-Za-z0-9_-'
}

mkdir -p "$runtime_dir/libexec" "$runtime_dir/applescript" "$runtime_dir/shell"
cp "$repo_dir/libexec/bind-codex-session" "$runtime_dir/libexec/"
cp "$repo_dir/libexec/backfill-codex-sessions" "$runtime_dir/libexec/"
cp "$repo_dir/libexec/identify-ghostty-surface" "$runtime_dir/libexec/"
cp "$repo_dir/libexec/restore-codex-sessions" "$runtime_dir/libexec/"
cp "$repo_dir"/applescript/*.applescript "$runtime_dir/applescript/"
cp "$repo_dir/shell/ghostx.zsh" "$runtime_dir/shell/"
chmod 755 \
  "$runtime_dir/libexec/backfill-codex-sessions" \
  "$runtime_dir/libexec/bind-codex-session" \
  "$runtime_dir/libexec/identify-ghostty-surface" \
  "$runtime_dir/libexec/restore-codex-sessions"
chmod 644 "$runtime_dir"/applescript/*.applescript "$runtime_dir/shell/ghostx.zsh"

mkdir -p "$(dirname -- "$ghostty_config")"
touch "$ghostty_config"
if ! grep -Fq '# >>> ghostx >>>' "$ghostty_config"; then
  if [ -s "$ghostty_config" ] && [ "$(tail -c 1 "$ghostty_config" | wc -l | tr -d ' ')" -eq 0 ]; then
    printf '\n' >>"$ghostty_config"
  fi
  {
    printf '# >>> ghostx >>>\n'
    cat "$repo_dir/config/ghostty.conf"
    printf '# <<< ghostx <<<\n'
  } >>"$ghostty_config"
fi

mkdir -p "$codex_dir"
if [ ! -f "$hooks_file" ]; then
  printf '%s\n' '{"hooks":{}}' >"$hooks_file"
fi
hooks_mode=$(stat -f '%Lp' "$hooks_file")
/usr/bin/plutil -convert json -o - "$hooks_file" >/dev/null

ensure_codex_hook() {
  event_name=$1
  matcher_value=$2
  status_message=$3
  event_path="hooks.$event_name"
  ghostx_hook_present=0
  ghostx_hook_index=""

  if /usr/bin/plutil -type "$event_path" "$hooks_file" >/dev/null 2>&1; then
    event_count=$(/usr/bin/plutil -extract "$event_path" raw -o - "$hooks_file" 2>/dev/null || printf '0')
    event_index=0
    while [ "$event_index" -lt "$event_count" ]; do
      installed_command=$(
        /usr/bin/plutil -extract "$event_path.$event_index.hooks.0.command" raw -o - "$hooks_file" 2>/dev/null || true
      )
      case "$installed_command" in
        *ghostx/runtime/libexec/bind-codex-session*)
          ghostx_hook_present=1
          ghostx_hook_index=$event_index
          break
          ;;
      esac
      event_index=$((event_index + 1))
    done
  fi

  tmp_hooks=$(mktemp "$codex_dir/hooks.XXXXXX")
  cp "$hooks_file" "$tmp_hooks"

  if [ "$ghostx_hook_present" -eq 0 ]; then
    if ! /usr/bin/plutil -type hooks "$tmp_hooks" >/dev/null 2>&1; then
      /usr/bin/plutil -insert hooks -dictionary "$tmp_hooks"
    fi
    if ! /usr/bin/plutil -type "$event_path" "$tmp_hooks" >/dev/null 2>&1; then
      /usr/bin/plutil -insert "$event_path" -array "$tmp_hooks"
    fi

    hook_index=$(/usr/bin/plutil -extract "$event_path" raw -o - "$tmp_hooks")
    hook_path="$event_path.$hook_index"
    /usr/bin/plutil -insert "$hook_path" -dictionary "$tmp_hooks"
    if [ -n "$matcher_value" ]; then
      /usr/bin/plutil -insert "$hook_path.matcher" -string "$matcher_value" "$tmp_hooks"
    fi
    /usr/bin/plutil -insert "$hook_path.hooks" -array "$tmp_hooks"
    /usr/bin/plutil -insert "$hook_path.hooks.0" -dictionary "$tmp_hooks"
    /usr/bin/plutil -insert "$hook_path.hooks.0.type" -string 'command' "$tmp_hooks"
    /usr/bin/plutil -insert "$hook_path.hooks.0.command" -string "$runtime_dir/libexec/bind-codex-session" "$tmp_hooks"
    /usr/bin/plutil -insert "$hook_path.hooks.0.timeout" -integer 10 "$tmp_hooks"
    /usr/bin/plutil -insert "$hook_path.hooks.0.statusMessage" -string "$status_message" "$tmp_hooks"
  else
    hook_path="$event_path.$ghostx_hook_index"
    if /usr/bin/plutil -type "$hook_path.hooks.0.timeout" "$tmp_hooks" >/dev/null 2>&1; then
      /usr/bin/plutil -replace "$hook_path.hooks.0.timeout" -integer 10 "$tmp_hooks"
    else
      /usr/bin/plutil -insert "$hook_path.hooks.0.timeout" -integer 10 "$tmp_hooks"
    fi
    if [ -n "$matcher_value" ]; then
      if /usr/bin/plutil -type "$hook_path.matcher" "$tmp_hooks" >/dev/null 2>&1; then
        /usr/bin/plutil -replace "$hook_path.matcher" -string "$matcher_value" "$tmp_hooks"
      else
        /usr/bin/plutil -insert "$hook_path.matcher" -string "$matcher_value" "$tmp_hooks"
      fi
    fi
  fi

  /usr/bin/plutil -convert json -r "$tmp_hooks"
  mv "$tmp_hooks" "$hooks_file"
  chmod "$hooks_mode" "$hooks_file"
}

ensure_codex_hook \
  SessionStart \
  'startup|resume|clear' \
  'Binding this Codex session to its terminal'
ensure_codex_hook \
  UserPromptSubmit \
  '' \
  'Saving this Codex session for Ghostty restoration'

touch "$zshrc"
if ! grep -Fq '# >>> ghostx >>>' "$zshrc"; then
  if [ -s "$zshrc" ] && [ "$(tail -c 1 "$zshrc" | wc -l | tr -d ' ')" -eq 0 ]; then
    printf '\n' >>"$zshrc"
  fi
  cat >>"$zshrc" <<'EOF'
# >>> ghostx >>>
_ghostx_integration="${XDG_DATA_HOME:-$HOME/.local/share}/ghostx/runtime/shell/ghostx.zsh"
[[ -r "$_ghostx_integration" ]] && source "$_ghostx_integration"
unset _ghostx_integration
# <<< ghostx <<<
EOF
fi

# Installing into an already-running Ghostty process must not make the next
# newly opened shell replay commands into terminals that are currently in use.
# Mark only the current process set as handled; a future Ghostty launch gets a
# different process identity and performs the normal restoration.
instance_id=$(ghostty_instance_id)
if [ -n "$instance_id" ]; then
  mkdir -p "$state_dir/run"
  printf '%s\n' "$(date +%s):installed" >"$state_dir/run/restored-$instance_id"
fi

if [ -z "${GHOSTX_SKIP_BACKFILL:-}" ]; then
  backfilled_sessions=$("$runtime_dir/libexec/backfill-codex-sessions" 2>/dev/null || printf '0')
else
  backfilled_sessions=0
fi

printf '%s\n' "Ghostx installed."
printf '%s\n' "Backfilled $backfilled_sessions running Codex session(s)."
printf '%s\n' "Next: continue an existing Codex session, start one, or resume one in Ghostty."
printf '%s\n' "Open /hooks once and trust the Ghostx hooks if they are pending review."
