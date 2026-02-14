#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ID="xbar-hosts-switcher"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/${PLUGIN_ID}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/${PLUGIN_ID}"
PROFILES_DIR="${CONFIG_DIR}/profiles"

SAFE_URL="https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
SAFE_BASENAME="SAFE"
UNSAFE_BASENAME="UNSAFE"

SAFE_FILE="${PROFILES_DIR}/${SAFE_BASENAME}.hosts"
UNSAFE_FILE="${PROFILES_DIR}/${UNSAFE_BASENAME}.hosts"

LAST_CHECK_EPOCH_FILE="${CACHE_DIR}/last_check_epoch"
UPSTREAM_LASTMOD_FILE="${CACHE_DIR}/upstream_last_modified.txt"
LAST_ERROR_FILE="${CACHE_DIR}/last_error.txt"

CHECK_INTERVAL_SECONDS=21600
ETC_HOSTS="/etc/hosts"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="${SELF_DIR}/$(basename "$0")"

SAFE_CHANGED=0

ensure_dirs() {
  mkdir -p "$PROFILES_DIR" "$CACHE_DIR"
}

init_profiles() {
  if [[ ! -f "$UNSAFE_FILE" ]]; then
    cat > "$UNSAFE_FILE" <<'EOF'
##
# Minimal macOS hosts file
##
127.0.0.1 localhost
255.255.255.255 broadcasthost
::1 localhost
EOF
  fi

  if [[ ! -f "$SAFE_FILE" ]]; then
    cat > "$SAFE_FILE" <<'EOF'
# SAFE profile placeholder.
# It will be replaced by StevenBlack on first successful fetch.
127.0.0.1 localhost
EOF
  fi
}

now_epoch() { date +%s; }

read_epoch_or_zero() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cat "$f" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

file_mtime_human() {
  local f="$1"
  if [[ -f "$f" ]]; then
    stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$f"
  else
    echo "unknown"
  fi
}

read_file_or_unknown() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cat "$f" 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

encode_b64() {
  printf '%s' "$1" | /usr/bin/base64 | tr -d '\n'
}

decode_b64() {
  printf '%s' "$1" | /usr/bin/base64 -D
}

save_upstream_last_modified() {
  local headers="$1"
  local lm
  lm="$(tr -d '\r' < "$headers" | grep -i '^Last-Modified:' | head -n 1 | cut -d' ' -f2- || true)"
  if [[ -n "${lm:-}" ]]; then
    printf '%s\n' "$lm" > "$UPSTREAM_LASTMOD_FILE"
  fi
}

fetch_safe_if_needed() {
  local now last age tmp headers
  now="$(now_epoch)"
  last="$(read_epoch_or_zero "$LAST_CHECK_EPOCH_FILE")"
  age=$(( now - last ))

  if (( age < CHECK_INTERVAL_SECONDS )); then
    return 0
  fi

  printf '%s\n' "$now" > "$LAST_CHECK_EPOCH_FILE"

  tmp="${CACHE_DIR}/SAFE.download.tmp"
  headers="${CACHE_DIR}/SAFE.headers.tmp"

  if ! curl -fsSL -D "$headers" -o "$tmp" "$SAFE_URL"; then
    rm -f "$tmp" "$headers" 2>/dev/null || true
    return 0
  fi

  save_upstream_last_modified "$headers"
  rm -f "$headers" 2>/dev/null || true

  if [[ -f "$SAFE_FILE" ]] && cmp -s "$tmp" "$SAFE_FILE"; then
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi

  mv -f "$tmp" "$SAFE_FILE"
}

force_refresh_safe() {
  SAFE_CHANGED=0

  local tmp headers
  tmp="${CACHE_DIR}/SAFE.download.tmp"
  headers="${CACHE_DIR}/SAFE.headers.tmp"

  if curl -fsSL -D "$headers" -o "$tmp" "$SAFE_URL"; then
    save_upstream_last_modified "$headers"
    rm -f "$headers" 2>/dev/null || true

    if [[ ! -f "$SAFE_FILE" ]] || ! cmp -s "$tmp" "$SAFE_FILE"; then
      mv -f "$tmp" "$SAFE_FILE"
      SAFE_CHANGED=1
    else
      rm -f "$tmp" 2>/dev/null || true
    fi
  else
    rm -f "$tmp" "$headers" 2>/dev/null || true
  fi

  printf '%s\n' "$(now_epoch)" > "$LAST_CHECK_EPOCH_FILE"
}

list_profile_files() {
  shopt -s nullglob
  local f
  for f in "$PROFILES_DIR"/*; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == ".DS_Store" ]] && continue
    printf '%s\n' "$f"
  done
}

detect_active_profile_file() {
  local f
  while IFS= read -r f; do
    if cmp -s "$f" "$ETC_HOSTS" 2>/dev/null; then
      printf '%s\n' "$f"
      return 0
    fi
  done < <(list_profile_files)

  printf '%s\n' ""
}

hosts_has_stevenblack_signature() {
  grep -qiE 'stevenblack|github\.com/StevenBlack/hosts' "$ETC_HOSTS" 2>/dev/null
}

title_for_active() {
  local active_file="$1"
  if [[ -z "$active_file" ]]; then
    echo "⚙️ CUSTOM"
    return 0
  fi

  local base
  base="$(basename "$active_file")"

  if [[ "$base" == "${SAFE_BASENAME}.hosts" ]]; then
    echo "✅ SAFE"
  elif [[ "$base" == "${UNSAFE_BASENAME}.hosts" ]]; then
    echo "❌ UNSAFE"
  else
    echo "🧩 ${base}"
  fi
}

count_blocked_domains() {
  local src="$1"
  [[ -f "$src" ]] || { echo 0; return; }

  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      ip=$1
      if (ip != "0.0.0.0" && ip != "127.0.0.1") next

      for (i=2; i<=NF; i++) {
        host=$i
        sub(/#.*/, "", host)
        gsub(/[[:space:]]+/, "", host)
        if (host == "") continue
        if (host == "localhost") continue
        if (host == "broadcasthost") continue
        print host
      }
    }
  ' "$src" | sort -u | wc -l | tr -d ' '
}

apply_profile_file() {
  local src="$1"
  [[ -f "$src" ]] || exit 0

  rm -f "$LAST_ERROR_FILE" 2>/dev/null || true

  local backup="/etc/hosts.xbar.backup.$(date +%Y%m%d%H%M%S)"

  if ! sudo -v 2> "$LAST_ERROR_FILE"; then
    exit 1
  fi

  if ! sudo cp /etc/hosts "$backup" 2>> "$LAST_ERROR_FILE"; then
    exit 1
  fi

  if ! sudo /usr/bin/install -m 644 -o root -g wheel "$src" /etc/hosts 2>> "$LAST_ERROR_FILE"; then
    exit 1
  fi

  rm -f "$LAST_ERROR_FILE" 2>/dev/null || true
}

open_profiles_folder() {
  /usr/bin/open "$PROFILES_DIR" >/dev/null 2>&1 || true
}

open_active_profile_in_default_text_editor() {
  local active_file
  active_file="$(detect_active_profile_file)"

  if [[ -n "$active_file" ]]; then
    /usr/bin/open -t "$active_file" >/dev/null 2>&1 || true
  else
    /usr/bin/open -t "$ETC_HOSTS" >/dev/null 2>&1 || true
  fi
}

handle_actions() {
  local action="${1:-}"
  case "$action" in
    applyfile)
      local b64="${2:-}"
      local src
      src="$(decode_b64 "$b64")"

      if [[ "$src" == "$SAFE_FILE" ]]; then
        force_refresh_safe
        apply_profile_file "$SAFE_FILE"
      else
        apply_profile_file "$src"
      fi
      exit 0
      ;;
    openactive)
      open_active_profile_in_default_text_editor
      exit 0
      ;;
    openprofiles)
      open_profiles_folder
      exit 0
      ;;
  esac
}

main_menu() {
  ensure_dirs
  init_profiles
  fetch_safe_if_needed

  local active_file
  active_file="$(detect_active_profile_file)"

  local title
  title="$(title_for_active "$active_file")"

  local count_source blocked_count
  if [[ -n "$active_file" ]]; then
    count_source="$active_file"
  else
    count_source="$ETC_HOSTS"
  fi
  blocked_count="$(count_blocked_domains "$count_source")"

  local safe_synced upstream_lastmod hosts_mtime
  safe_synced="$(file_mtime_human "$SAFE_FILE")"
  upstream_lastmod="$(read_file_or_unknown "$UPSTREAM_LASTMOD_FILE")"
  hosts_mtime="$(file_mtime_human "$ETC_HOSTS")"

  echo "$title"
  echo "---"

  echo "Blocked domains: ${blocked_count}"
  echo "---"

  if [[ -f "$LAST_ERROR_FILE" ]]; then
    echo "⚠️ Last error: $(tail -n 1 "$LAST_ERROR_FILE" | tr -d '\r')"
    echo "---"
  fi

  local f base label prefix b64
  while IFS= read -r f; do
    base="$(basename "$f")"

    if [[ "$base" == "${SAFE_BASENAME}.hosts" ]]; then
      label="SAFE (StevenBlack)"
    elif [[ "$base" == "${UNSAFE_BASENAME}.hosts" ]]; then
      label="UNSAFE (minimal)"
    else
      label="$base"
    fi

    if cmp -s "$f" "$ETC_HOSTS" 2>/dev/null; then
      prefix="✓"
    else
      prefix=""
    fi

    b64="$(encode_b64 "$f")"
    echo "${prefix} ${label} | bash=/bin/bash param1='$SELF' param2=applyfile param3='$b64' terminal=false refresh=true"
  done < <(list_profile_files)

  echo "---"
  echo "/etc/hosts last modified: ${hosts_mtime}"
  echo "SAFE profile last synced: ${safe_synced}"
  echo "StevenBlack upstream last modified: ${upstream_lastmod}"
  echo "---"
  echo "Open active hosts file | bash=/bin/bash param1='$SELF' param2=openactive terminal=false refresh=false"
  echo "Open profiles folder | bash=/bin/bash param1='$SELF' param2=openprofiles terminal=false refresh=false"
}

handle_actions "${1:-}" "${2:-}"
main_menu