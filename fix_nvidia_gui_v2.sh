#!/usr/bin/env bash
#
# fix_nvidia_gui_v2.sh — replace Ubuntu's apt-shipped nvidia-settings (and
# the matching GTK2/GTK3 panel libraries) with the versions extracted from
# the upstream NVIDIA .run installer. Works around the long-running
# "double free or corruption (!prev)" crash that ships with the 510/590
# Ubuntu package on some systems.
#
# Notable differences vs. v1:
#   * Uses `dpkg-divert` so the apt-shipped binaries are renamed aside,
#     not silently overwritten. apt will never replace our copies, and
#     `--revert` actually puts the original files back.
#   * Uses `apt-mark hold` in addition to dpkg-divert — pin-priority -1
#     on an already-installed package is a non-standard pattern and does
#     not survive `apt remove` / `apt install` of nvidia-settings.
#   * No hard-coded "590.44.01" compat symlink. The compat link is built
#     from whatever version is actually on the system, if it is needed.
#   * Auto-detects the .run installer, or accepts a path as argument.
#   * Verifies extracted files exist before copying.
#   * Cleans the extract directory on exit (success or failure).
#
# Usage:
#   sudo ./fix_nvidia_gui_v2.sh install [path/to/NVIDIA-Linux-*.run]
#   sudo ./fix_nvidia_gui_v2.sh revert
#   sudo ./fix_nvidia_gui_v2.sh status
#   sudo ./fix_nvidia_gui_v2.sh help
#
set -uo pipefail

TARGET_LIB_DIR=/usr/lib/x86_64-linux-gnu
TARGET_BIN_DIR=/usr/bin
EXTRACT_DIR=$(mktemp -d -t nvidia_extract.XXXXXX)
STATE_FILE=/var/lib/fix_nvidia_gui_v2.state    # records files we diverted

# Files we manage. The Ubuntu nvidia-settings package ships at least these.
MANAGED_BIN=( "$TARGET_BIN_DIR/nvidia-settings" )
# Library basenames (without version suffix). Real filenames have $VERSION
# appended.
MANAGED_LIB_BASES=( libnvidia-gtk2 libnvidia-gtk3 )

cleanup() { [ -n "${EXTRACT_DIR:-}" ] && rm -rf "$EXTRACT_DIR"; }
trap cleanup EXIT

log()  { printf '\e[1;34m[INFO]\e[0m %s\n'  "$*"; }
warn() { printf '\e[1;33m[WARN]\e[0m %s\n'  "$*" >&2; }
err()  { printf '\e[1;31m[ERROR]\e[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Please run as root (sudo)."

show_help() {
  sed -n '2,30p' "$0"
}

# --- locate the .run file -------------------------------------------------

find_run_file() {
  local arg="${1:-}"
  if [ -n "$arg" ]; then
    [ -f "$arg" ] || die ".run file not found: $arg"
    printf '%s\n' "$arg"
    return
  fi
  shopt -s nullglob
  local candidates=( ./NVIDIA-Linux-*.run )
  shopt -u nullglob
  case ${#candidates[@]} in
    0) die "No NVIDIA-Linux-*.run file in $(pwd). Pass one as argument." ;;
    1) printf '%s\n' "${candidates[0]}" ;;
    *) err "Multiple .run files found; pick one:"
       printf '  %s\n' "${candidates[@]}" >&2; exit 1 ;;
  esac
}

# Extract version "595.71.05" from "NVIDIA-Linux-x86_64-595.71.05.run".
parse_version() {
  local file="$1" v
  v=$(basename "$file" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  [ -n "$v" ] || die "Could not parse version from $file"
  printf '%s\n' "$v"
}

# --- divert / undivert helpers --------------------------------------------

is_diverted() {
  dpkg-divert --list "$1" 2>/dev/null | grep -q "$1"
}

divert_and_install() {
  # $1: target path (e.g. /usr/bin/nvidia-settings)
  # $2: source path (e.g. $EXTRACT_DIR/nvidia-settings)
  # $3: mode (e.g. 0755 or 0644)
  local target="$1" source="$2" mode="$3"
  if [ ! -f "$source" ]; then
    warn "source missing, skipping: $source"
    return 0
  fi
  if [ -e "$target" ] && ! is_diverted "$target"; then
    log "Diverting $target -> $target.distrib"
    dpkg-divert --add --rename --divert "${target}.distrib" "$target" \
      || die "dpkg-divert failed for $target"
  fi
  log "Installing $source -> $target"
  install -m "$mode" "$source" "$target"
  echo "$target" >> "$STATE_FILE"
}

undivert() {
  # $1: target path
  local target="$1"
  if is_diverted "$target"; then
    log "Removing our copy at $target"
    rm -f "$target"
    log "Restoring distribution copy of $target"
    dpkg-divert --remove --rename "$target" \
      || warn "dpkg-divert --remove failed for $target"
  fi
}

# --- subcommands ----------------------------------------------------------

do_status() {
  echo "Diverted entries currently in place:"
  for p in "${MANAGED_BIN[@]}"; do
    if is_diverted "$p"; then echo "  [active]  $p"
    else                      echo "  [unset]   $p"; fi
  done
  shopt -s nullglob
  for lib_base in "${MANAGED_LIB_BASES[@]}"; do
    for f in "$TARGET_LIB_DIR/${lib_base}.so."*; do
      if is_diverted "$f"; then echo "  [active]  $f"; fi
    done
  done
  shopt -u nullglob

  echo
  echo "apt-mark hold state for nvidia-settings:"
  apt-mark showhold | grep -E '^nvidia-settings$' \
    || echo "  (not held)"

  echo
  if [ -f "$STATE_FILE" ]; then
    echo "Recorded state file ($STATE_FILE):"
    sed 's/^/  /' "$STATE_FILE"
  else
    echo "No state file; nothing has been recorded by previous installs."
  fi
}

do_install() {
  local run_file version
  run_file=$(find_run_file "${1:-}")
  version=$(parse_version "$run_file")
  log "Driver: $run_file (version $version)"

  log "Phase 1: extracting installer payload..."
  chmod +x "$run_file" 2>/dev/null || true
  "$run_file" --extract-only --target "$EXTRACT_DIR" >/dev/null \
    || die "Could not extract $run_file"

  : > "$STATE_FILE"

  log "Phase 2: replacing nvidia-settings binary..."
  divert_and_install \
    "$TARGET_BIN_DIR/nvidia-settings" \
    "$EXTRACT_DIR/nvidia-settings" \
    0755

  log "Phase 3: replacing libnvidia-gtk{2,3}..."
  for base in "${MANAGED_LIB_BASES[@]}"; do
    local src="$EXTRACT_DIR/${base}.so.${version}"
    local dst="$TARGET_LIB_DIR/${base}.so.${version}"
    if [ ! -f "$src" ]; then
      warn "Not present in installer payload, skipping: ${base}.so.${version}"
      continue
    fi
    divert_and_install "$dst" "$src" 0644

    # Also (re)create the unversioned and SONAME symlinks so the dynamic
    # linker actually finds the new library.
    ln -sf "$dst" "$TARGET_LIB_DIR/${base}.so"
    # SONAME for libnvidia-gtkN ships as libnvidia-gtkN.so (no extra digit
    # in NVIDIA's case). If you see needed-by errors for a specific suffix,
    # add a compat link here. Example for the legacy 590.44.01 SONAME:
    #   ln -sf "$dst" "$TARGET_LIB_DIR/${base}.so.590.44.01"
    # but don't do that unconditionally — it just confuses ldconfig.
  done

  ldconfig

  log "Phase 4: telling apt not to upgrade these files (apt-mark hold)..."
  apt-mark hold nvidia-settings \
    || warn "apt-mark hold failed; you may want to investigate."

  log "Install complete. Run 'nvidia-settings' to test."
  log "Use '$0 status' to see what is currently diverted."
  log "Use '$0 revert' to undo this."
}

do_revert() {
  log "Removing apt hold..."
  apt-mark unhold nvidia-settings 2>/dev/null || true

  log "Reverting binary diversions..."
  for p in "${MANAGED_BIN[@]}"; do
    undivert "$p"
  done

  log "Reverting library diversions..."
  shopt -s nullglob
  for base in "${MANAGED_LIB_BASES[@]}"; do
    for f in "$TARGET_LIB_DIR/${base}.so."*; do
      if is_diverted "$f"; then
        undivert "$f"
      fi
    done
  done
  shopt -u nullglob

  log "Refreshing ldconfig and reinstalling the apt package to ensure"
  log "all distribution files are present and consistent..."
  apt-get update -y || warn "apt-get update failed (network?); continuing"
  apt-get install --reinstall -y nvidia-settings \
    || warn "apt-get install --reinstall nvidia-settings failed."
  ldconfig

  rm -f "$STATE_FILE"

  log "Revert complete."
}

# --- main -----------------------------------------------------------------

case "${1:-help}" in
  install) shift; do_install "$@" ;;
  revert)  do_revert ;;
  status)  do_status ;;
  help|-h|--help) show_help ;;
  *)       show_help ;;
esac
