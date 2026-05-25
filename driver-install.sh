#!/usr/bin/env bash
#
# driver-install.sh — Install the NVIDIA proprietary driver from an
# upstream .run installer, with DKMS, with Secure Boot module signing using
# a custom Machine Owner Key (MOK).
#
# Reference: https://github.com/NVIDIA/open-gpu-kernel-modules
#
# Notable differences vs. the typical copy-paste recipe:
#   * Auto-detects the .run file in the current directory, or accepts one as
#     an argument. No hard-coded version.
#   * Verifies the MOK key/cert exist, and (optionally) generates them if
#     missing.
#   * Checks whether the MOK is actually enrolled in shim before signing,
#     and walks the user through `mokutil --import` if it isn't. Signing
#     without enrolling produces modules the kernel refuses to load under
#     Secure Boot.
#   * Detects GPU generation and warns before passing
#     --kernel-module-type=open on hardware that does not support it
#     (Maxwell, Pascal — i.e. GTX 9xx / GTX 10xx).
#   * TTY-safe prompts, no `set -e` foot-gun with `read`.
#   * Tells the user how to boot to terminal-only mode (the equivalent of
#     old runlevel 3) via GRUB *and* via `systemctl set-default`, so they
#     can install the driver with X stopped.
#
# Usage:
#   sudo ./driver-install.sh                       # auto-detect .run
#   sudo ./driver-install.sh /path/to/NVIDIA.run   # explicit installer
#   sudo ./driver-install.sh --proprietary         # force closed-source modules
#   sudo ./driver-install.sh --open                # force open kernel modules
#   sudo ./driver-install.sh --setup-mok           # only generate MOK and enroll
#   sudo ./driver-install.sh --skip-isolate        # don't switch runlevels
#
set -uo pipefail

MOK_DIR=/root/module-signing
MOK_KEY="$MOK_DIR/MOK.key"
MOK_CRT="$MOK_DIR/MOK.der"
RUN_FILE=""
MODULE_TYPE=""       # "open" or "proprietary" (auto-detected if empty)
SKIP_ISOLATE=0
SETUP_MOK_ONLY=0

# ---------- helpers ---------------------------------------------------------

log()  { printf '\e[1;34m[INFO]\e[0m %s\n'  "$*"; }
warn() { printf '\e[1;33m[WARN]\e[0m %s\n'  "$*" >&2; }
err()  { printf '\e[1;31m[ERROR]\e[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# TTY-safe prompt. Returns 0 if the user typed something matching ^[Yy], else 1.
ask_yn() {
  local prompt="$1" default="${2:-n}" reply=""
  if [ ! -t 0 ] && [ ! -r /dev/tty ]; then
    log "$prompt [no TTY, defaulting to $default]"
    [ "$default" = "y" ]; return $?
  fi
  if [ -r /dev/tty ]; then
    read -r -p "$prompt " reply < /dev/tty || reply="$default"
  else
    read -r -p "$prompt " reply || reply="$default"
  fi
  [[ "${reply:-$default}" =~ ^[Yy]$ ]]
}

# Same idea but plain "press enter" gate.
pause() {
  local prompt="${1:-Press Enter to continue...}"
  if [ ! -t 0 ] && [ ! -r /dev/tty ]; then
    log "(no TTY; not waiting)"; return 0
  fi
  if [ -r /dev/tty ]; then
    # shellcheck disable=SC2162
    read -p "$prompt" _ < /dev/tty || true
  else
    # shellcheck disable=SC2162
    read -p "$prompt" _ || true
  fi
}

# ---------- argument parsing -----------------------------------------------

for arg in "$@"; do
  case "$arg" in
    --open)         MODULE_TYPE=open ;;
    --proprietary)  MODULE_TYPE=proprietary ;;
    --skip-isolate) SKIP_ISOLATE=1 ;;
    --setup-mok)    SETUP_MOK_ONLY=1 ;;
    -h|--help)
      sed -n '2,40p' "$0"; exit 0 ;;
    -*)
      die "Unknown flag: $arg" ;;
    *)
      RUN_FILE="$arg" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "Please run with sudo or as root."

# ---------- locate the .run installer --------------------------------------

if [ -z "$RUN_FILE" ] && [ "$SETUP_MOK_ONLY" -eq 0 ]; then
  shopt -s nullglob
  candidates=( ./NVIDIA-Linux-*.run )
  shopt -u nullglob
  if [ ${#candidates[@]} -eq 1 ]; then
    RUN_FILE="${candidates[0]}"
  elif [ ${#candidates[@]} -eq 0 ]; then
    die "No NVIDIA-Linux-*.run file in current directory. Pass one as argument."
  else
    err "Multiple .run files found; pick one and pass it explicitly:"
    printf '  %s\n' "${candidates[@]}" >&2
    exit 1
  fi
fi

if [ -n "$RUN_FILE" ]; then
  [ -f "$RUN_FILE" ] || die ".run file not found: $RUN_FILE"
  log "Using installer: $RUN_FILE"
fi

# ---------- MOK key setup --------------------------------------------------

ensure_mok_keys() {
  if [ -f "$MOK_KEY" ] && [ -f "$MOK_CRT" ]; then
    log "Found existing MOK keypair under $MOK_DIR"
    return 0
  fi

  warn "MOK keypair not found at $MOK_KEY / $MOK_CRT"
  if ! ask_yn "Generate a fresh MOK keypair now? [y/N]:" n; then
    die "Aborting. Create the keypair manually and rerun, or use --setup-mok."
  fi

  mkdir -p "$MOK_DIR"
  chmod 700 "$MOK_DIR"
  log "Generating MOK keypair (RSA-2048, 100-year validity)..."
  openssl req -new -x509 \
    -newkey rsa:2048 \
    -keyout "$MOK_KEY" \
    -outform DER \
    -out "$MOK_CRT" \
    -nodes \
    -days 36500 \
    -subj "/CN=Local NVIDIA module signing key/" \
    || die "openssl failed to generate MOK keypair."
  chmod 600 "$MOK_KEY"
  chmod 644 "$MOK_CRT"
  log "Wrote $MOK_KEY and $MOK_CRT"
}

ensure_mok_enrolled() {
  # If mokutil isn't installed there's no shim, so we're either on a
  # legacy-BIOS box or in a container — nothing to enrol.
  if ! command -v mokutil >/dev/null 2>&1; then
    warn "mokutil not installed; cannot verify MOK enrolment. Skipping."
    return 0
  fi

  # Not a Secure Boot system at all → nothing to do.
  if ! mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
    log "Secure Boot is not enabled — MOK enrolment not required."
    return 0
  fi

  if mokutil --test-key "$MOK_CRT" 2>&1 | grep -qi 'is already enrolled'; then
    log "MOK is already enrolled in shim — good."
    return 0
  fi

  warn "Secure Boot is ON and your MOK is NOT yet enrolled."
  warn "If you proceed without enrolling, the kernel will refuse to load"
  warn "your freshly signed nvidia modules and nvidia-smi will fail."
  echo
  echo "  To enrol now:"
  echo "    sudo mokutil --import $MOK_CRT"
  echo "  Pick a one-time password when prompted, then reboot. At the"
  echo "  blue MokManager screen choose 'Enroll MOK' → 'Continue' →"
  echo "  enter the same password → reboot."
  echo

  if ask_yn "Run 'mokutil --import' now? [y/N]:" n; then
    mokutil --import "$MOK_CRT" \
      || die "mokutil --import failed."
    warn "Enrolment scheduled. Reboot and complete the MOK enrolment in"
    warn "MokManager BEFORE rerunning this script to install the driver."
    exit 0
  fi

  # The user declined (or there was no TTY). Continuing into the installer
  # would build modules signed with a key the kernel does not trust; modprobe
  # would silently reject them under Secure Boot and nvidia-smi would fail.
  # Bail loudly instead of producing a half-installed driver.
  die "MOK is not enrolled and you declined enrolment. Refusing to install — \
the kernel would reject the signed modules under Secure Boot. Enrol first with:
    sudo mokutil --import $MOK_CRT
then reboot, complete enrolment in MokManager, and rerun this script."
}

ensure_mok_keys
ensure_mok_enrolled

if [ "$SETUP_MOK_ONLY" -eq 1 ]; then
  log "MOK setup complete. Rerun without --setup-mok to install the driver."
  exit 0
fi

# ---------- GPU generation check ------------------------------------------

if [ -z "$MODULE_TYPE" ]; then
  gpu_line=$(lspci 2>/dev/null \
    | grep -iE 'vga|3d controller|display controller' \
    | grep -i 'nvidia' \
    | head -1)
  if [ -z "$gpu_line" ]; then
    warn "No NVIDIA GPU detected via lspci. Defaulting to closed (proprietary) modules."
    MODULE_TYPE=proprietary
  else
    log "Detected GPU: $gpu_line"
    # Turing (TU1xx, RTX 20xx / GTX 16xx) and newer support open modules.
    # Pascal (GP1xx, GTX 10xx) and older do NOT.
    if echo "$gpu_line" | grep -qiE 'RTX|GTX 16[0-9]{2}|TU[0-9]|GA[0-9]|AD[0-9]|GH[0-9]|H100|A100|L4|L40'; then
      MODULE_TYPE=open
    else
      MODULE_TYPE=proprietary
      warn "Your GPU appears to be Pascal or older. Open kernel modules are"
      warn "NOT supported on Pascal/Maxwell/Kepler. Falling back to closed."
    fi
  fi
fi
log "Kernel module type: $MODULE_TYPE"

# ---------- prepare to install: stop the display server -------------------

if [ "$SKIP_ISOLATE" -eq 0 ]; then
  current_target=$(systemctl get-default 2>/dev/null || echo unknown)
  log "Current default systemd target: $current_target"
  current_state=$(systemctl is-active graphical.target 2>/dev/null || true)

  if [ "$current_state" = "active" ]; then
    cat <<'EOF'

Before installing, the display server (Xorg / Wayland) must NOT be using
the running NVIDIA modules. You have three options:

  1. One-shot: at the GRUB menu on the next boot, press 'e' to edit the
     selected entry, append the word "3" (or "systemd.unit=multi-user.target")
     to the end of the line that starts with "linux", then press Ctrl-X
     to boot. That single boot comes up in a TTY only.

  2. Permanent default = TTY:
        sudo systemctl set-default multi-user.target
        sudo reboot
     To go back to a desktop login screen:
        sudo systemctl set-default graphical.target
        sudo reboot

  3. Right now, in this session, isolate to the multi-user target. Your
     X session will close immediately.

EOF
    if ask_yn "Isolate to multi-user.target now? [y/N]:" n; then
      log "Switching to multi-user.target..."
      systemctl isolate multi-user.target
    else
      log "Not switching. If you proceed and X is still running, the"
      log "installer will likely refuse to swap out the in-use kernel module."
      pause "Press Enter when you are ready to proceed anyway (or Ctrl-C to abort)..."
    fi
  fi
fi

# ---------- run the NVIDIA installer --------------------------------------

log "Running NVIDIA installer with DKMS + MOK signing..."

# Note on flags:
#   --dkms                          : rebuild module on every kernel update
#   --module-signing-secret-key=    : MOK private key (PEM or DER, but PEM
#                                     is what `openssl req -keyout` writes
#                                     when -nodes is used)
#   --module-signing-public-key=    : MOK public cert (DER)
#   --kernel-module-type=open|prop. : pick driver flavour
#   --glvnd-egl-config-path=        : where to drop the GLVND vendor file;
#                                     on Ubuntu this is /usr/share/glvnd/egl_vendor.d
#   --silent or --no-questions      : not used here on purpose; let the
#                                     installer report any issue.
chmod +x "$RUN_FILE" 2>/dev/null || true

if ! "$RUN_FILE" \
      --dkms \
      --module-signing-secret-key="$MOK_KEY" \
      --module-signing-public-key="$MOK_CRT" \
      --glvnd-egl-config-path=/usr/share/glvnd/egl_vendor.d \
      --kernel-module-type="$MODULE_TYPE"; then
  err "NVIDIA installer reported a failure."
  err "Check /var/log/nvidia-installer.log for the cause."
  exit 1
fi

log "Installer finished."

# ---------- load the freshly built module ---------------------------------

if lsmod | awk '{print $1}' | grep -q '^nvidia'; then
  log "An NVIDIA module is already loaded; not reloading (reboot will pick"
  log "up the new build cleanly)."
else
  log "Loading nvidia module..."
  modprobe nvidia 2>&1 \
    || warn "modprobe nvidia failed; the module will load after reboot."
fi

# ---------- sanity check ---------------------------------------------------

if command -v nvidia-smi >/dev/null 2>&1; then
  if nvidia-smi >/dev/null 2>&1; then
    log "nvidia-smi reports the GPU and driver are working."
  else
    warn "nvidia-smi failed. If Secure Boot is on, double-check the MOK was"
    warn "actually enrolled (sudo mokutil --list-enrolled | grep -i 'Local NVIDIA')."
    warn "Otherwise: cat /var/log/nvidia-installer.log and dmesg | grep -i nvidia."
  fi
else
  warn "nvidia-smi not found on PATH; the install may not have completed."
fi

# ---------- reinstall nvidia-settings (optional, may be redundant) --------

cat <<'EOF'

Optional next steps:

  1. nvidia-settings GUI.
       The .run installer drops an nvidia-settings binary under
       /usr/bin/nvidia-settings already. If you prefer the Ubuntu package
       version (so it is tracked by apt), install it with:

         sudo apt-get install --reinstall -y nvidia-settings

       If your distro ships a broken nvidia-settings (the well-known
       'double free' crash on save), do NOT reinstall — see
       fix_nvidia_gui_v2.sh in this repo for the GUI-only workaround.

  2. Polkit helper.
       Ubuntu ships /usr/share/screen-resolution-extra/nvidia-polkit which
       must be executable for "save current configuration" to work from
       the GUI without sudo. The block below fixes that if it applies.

EOF

POLKIT_WRAPPER=/usr/share/screen-resolution-extra/nvidia-polkit
if [ -f "$POLKIT_WRAPPER" ] && [ ! -x "$POLKIT_WRAPPER" ]; then
  log "Marking $POLKIT_WRAPPER executable."
  chmod +x "$POLKIT_WRAPPER" || warn "chmod +x failed on $POLKIT_WRAPPER"
elif [ -f "$POLKIT_WRAPPER" ]; then
  log "$POLKIT_WRAPPER already executable."
else
  log "$POLKIT_WRAPPER not present (Ubuntu screen-resolution-extra not installed); skipping."
fi

log "All steps completed."

# Check whether the *running* default target is multi-user. `systemctl
# get-default` reads the persistent default symlink, which does NOT change
# when we did `systemctl isolate multi-user.target`. `is-active
# graphical.target` reflects the actual runtime state — if it is not active
# right now, we are sitting in a TTY and the user needs to know how to get
# the desktop back.
if [ "$SKIP_ISOLATE" -eq 0 ] \
   && ! systemctl is-active graphical.target >/dev/null 2>&1; then
  cat <<'EOF'

You are currently in multi-user (TTY) mode. To get the desktop back:
  - For this boot only:   sudo systemctl isolate graphical.target
  - Make graphical default again:
        sudo systemctl set-default graphical.target
        sudo reboot

EOF
fi

pause "Press Enter to exit..."
