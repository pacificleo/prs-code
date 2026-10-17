#!/bin/sh
set -e

# Lightweight ghostty CLI shim for shell integration (e.g. +ssh-cache).
# Ghostty shell integrations call "$GHOSTTY_BIN_DIR/ghostty" +ssh-cache to check
# or update the remote terminfo cache. Supacode bundles Ghostty as a framework
# (GhosttyKit) rather than a CLI executable; this shim handles +ssh-cache so
# shell integration works seamlessly without spawning the Supacode GUI app.

cache_dir="${XDG_STATE_HOME:-$HOME/.local/state}/ghostty"
cache_file="${cache_dir}/ssh_cache"

case "${1:-}" in
  +ssh-cache)
    shift
    if [ "$#" -eq 0 ]; then
      if [ -f "$cache_file" ]; then
        cat "$cache_file"
      fi
      exit 0
    fi
    for arg in "$@"; do
      case "$arg" in
        --host=*)
          host="${arg#--host=}"
          if [ -f "$cache_file" ] && grep -q "^${host}|" "$cache_file" 2>/dev/null; then
            exit 0
          else
            exit 1
          fi
          ;;
        --add=*)
          host="${arg#--add=}"
          mkdir -p "$cache_dir"
          now=$(date +%s)
          if [ -f "$cache_file" ]; then
            grep -v "^${host}|" "$cache_file" > "${cache_file}.tmp" 2>/dev/null || true
            mv "${cache_file}.tmp" "$cache_file"
          fi
          printf '%s|%s|xterm-ghostty\n' "$host" "$now" >> "$cache_file"
          chmod 600 "$cache_file" 2>/dev/null || true
          exit 0
          ;;
        --remove=*)
          host="${arg#--remove=}"
          if [ -f "$cache_file" ]; then
            grep -v "^${host}|" "$cache_file" > "${cache_file}.tmp" 2>/dev/null || true
            mv "${cache_file}.tmp" "$cache_file"
          fi
          exit 0
          ;;
        --clear)
          rm -f "$cache_file"
          exit 0
          ;;
      esac
    done
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
