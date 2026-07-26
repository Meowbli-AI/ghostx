# Ghostx restore integration for zsh.
#
# Every restored Ghostty surface starts a fresh shell. The first shell in a
# Ghostty process claims a one-shot lock and restores all mapped surfaces after
# Ghostty finishes rebuilding its native window state.

if [[ -o interactive && -z "${SSH_CONNECTION:-}" && "${TERM_PROGRAM:l}" == "ghostty" ]]; then
  _ghostx_runtime="${XDG_DATA_HOME:-$HOME/.local/share}/ghostx/runtime"
  case "${GHOSTX_SURFACE_ID:-}" in
    ????????-????-????-????-????????????) ;;
    *)
      if [[ -x "$_ghostx_runtime/libexec/identify-ghostty-surface" ]]; then
        _ghostx_surface_id="$("$_ghostx_runtime/libexec/identify-ghostty-surface" 2>/dev/null)"
        case "$_ghostx_surface_id" in
          ????????-????-????-????-????????????)
            export GHOSTX_SURFACE_ID="$_ghostx_surface_id"
            ;;
        esac
        unset _ghostx_surface_id
      fi
      ;;
  esac
  if [[ -x "$_ghostx_runtime/libexec/restore-codex-sessions" ]]; then
    "$_ghostx_runtime/libexec/restore-codex-sessions" >/dev/null 2>&1 &!
  fi
  unset _ghostx_runtime
fi
