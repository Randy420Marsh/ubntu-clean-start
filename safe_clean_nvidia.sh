#!/usr/bin/env bash
#
# safe_clean_nvidia.sh — Headless-safe NVIDIA / CUDA / cuDNN purge for Ubuntu.
#
# Tested targets: Ubuntu 22.04 (jammy) and 24.04 (noble).
#
# Goals:
#   * Remove every NVIDIA proprietary driver, CUDA toolkit, cuDNN, and related
#     library package.
#   * Drop loaded NVIDIA kernel modules where possible so the purge takes
#     effect without requiring a reboot.
#   * Remove leftover DKMS source trees, apt sources, signing keys, and
#     /etc/* config fragments that survive a normal `apt purge`.
#   * Be safe to run over SSH on a server with no GUI: never call into X,
#     never assume gdm/sddm/lightdm exist, never block on a closed stdin.
#
# Non-goals / explicit safety choices:
#   * Does NOT touch third-party DKMS modules like rtl8812au, 8188eu,
#     ax88179a, or v4l2loopback. Those are common on real systems (WiFi
#     adapters, USB ethernet, OBS virtual cameras) and removing them
#     silently can leave the user without networking. Use --purge-extra-dkms
#     to opt in.
#   * Does NOT blanket-purge every `rc` (config-only) package on the
#     system. Only `rc` packages whose name matches the NVIDIA/CUDA set
#     are removed.
#   * Does NOT remove nouveau blacklist files by default. Use
#     --restore-nouveau if you want the open-source driver back.
#
# Usage:
#   sudo ./safe_clean_nvidia.sh                # default safe purge
#   sudo ./safe_clean_nvidia.sh --dry-run      # show what would happen
#   sudo ./safe_clean_nvidia.sh --restore-nouveau
#   sudo ./safe_clean_nvidia.sh --purge-extra-dkms   # also remove WiFi/USB DKMS
#   sudo ./safe_clean_nvidia.sh --yes          # non-interactive, no reboot prompt
#
set -uo pipefail

DRY_RUN=0
RESTORE_NOUVEAU=0
PURGE_EXTRA_DKMS=0
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)            DRY_RUN=1 ;;
    --restore-nouveau)    RESTORE_NOUVEAU=1 ;;
    --purge-extra-dkms)   PURGE_EXTRA_DKMS=1 ;;
    -y|--yes)             ASSUME_YES=1 ;;
    -h|--help)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: please run with sudo or as root." >&2
  exit 1
fi

# run / dry-run wrapper. Always logs the command; only executes if not --dry-run.
run() {
  echo "+ $*"
  if [ "$DRY_RUN" -eq 0 ]; then
    "$@"
  fi
}

# Same as run() but for command strings that need shell features (pipes, globs).
run_sh() {
  echo "+ $*"
  if [ "$DRY_RUN" -eq 0 ]; then
    bash -c "$*"
  fi
}

# Read a prompt from the controlling TTY so the script still works when piped
# (e.g. `curl ... | sudo bash`).
prompt_yes_no() {
  local question="$1"
  local default="${2:-n}"
  local reply=""
  if [ "$ASSUME_YES" -eq 1 ]; then
    echo "$question [auto-yes]"
    return 0
  fi
  if [ ! -t 0 ] && [ ! -r /dev/tty ]; then
    echo "$question [no TTY, defaulting to $default]"
    [ "$default" = "y" ]
    return $?
  fi
  if [ -r /dev/tty ]; then
    read -r -p "$question " reply < /dev/tty || reply="$default"
  else
    read -r -p "$question " reply || reply="$default"
  fi
  [[ "${reply:-$default}" =~ ^[Yy]$ ]]
}

echo "===================================================="
echo " Safe NVIDIA / CUDA / cuDNN purge"
echo " Ubuntu 22.04 (jammy) + 24.04 (noble)"
[ "$DRY_RUN" -eq 1 ] && echo " *** DRY RUN — no changes will be made ***"
echo "===================================================="

# ----------------------------------------------------------------------------
# 1. Remember which display manager (if any) was active, then stop it.
#    On headless servers none of these exist; we simply skip.
# ----------------------------------------------------------------------------
echo "[1/9] Stopping any active display manager..."
ACTIVE_DM=""
for dm in gdm3 gdm sddm lightdm; do
  if systemctl is-active --quiet "$dm" 2>/dev/null; then
    ACTIVE_DM="$dm"
    run systemctl stop "$dm"
    break
  fi
done
[ -z "$ACTIVE_DM" ] && echo "    (no active display manager — fine on headless)"

# ----------------------------------------------------------------------------
# 2. Unload NVIDIA kernel modules so the purge can clean them out cleanly.
#    Order matters: dependents first.
# ----------------------------------------------------------------------------
echo "[2/9] Unloading NVIDIA kernel modules..."
for mod in nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia; do
  if lsmod | awk '{print $1}' | grep -qx "$mod"; then
    run modprobe -r "$mod" || echo "    (could not unload $mod; will be removed on reboot)"
  fi
done

# ----------------------------------------------------------------------------
# 3. Purge NVIDIA + CUDA + cuDNN + companion libraries.
#    All patterns are POSIX EREs; apt-get treats anything containing regex
#    metacharacters as a regex pattern.
# ----------------------------------------------------------------------------
echo "[3/9] Purging NVIDIA / CUDA / cuDNN packages..."
PKG_PATTERNS=(
  '^nvidia-.*'
  '^libnvidia-.*'
  '^xserver-xorg-video-nvidia.*'
  '^cuda-.*'
  '^cuda$'
  '^libcudnn.*'
  '^libcublas.*'
  '^libcufft.*'
  '^libcurand.*'
  '^libcusolver.*'
  '^libcusparse.*'
  '^libnpp.*'
  '^libnccl.*'
  '^libnvjpeg.*'
  '^libnvinfer.*'
  '^libcutensor.*'
  '^tensorrt.*'
  '^nccl-.*'
)
run apt-get purge -y "${PKG_PATTERNS[@]}" || true

# ----------------------------------------------------------------------------
# 4. Remove apt sources and signing keys added by the CUDA / NVIDIA repos.
# ----------------------------------------------------------------------------
echo "[4/9] Removing CUDA / NVIDIA apt sources and keys..."
run_sh "rm -f /etc/apt/sources.list.d/cuda*.list /etc/apt/sources.list.d/cuda*.sources"
run_sh "rm -f /etc/apt/sources.list.d/nvidia*.list /etc/apt/sources.list.d/nvidia*.sources"
run_sh "rm -f /etc/apt/sources.list.d/cudnn*.list /etc/apt/sources.list.d/cudnn*.sources"
run_sh "rm -f /usr/share/keyrings/cuda*.gpg /usr/share/keyrings/nvidia*.gpg /usr/share/keyrings/cudnn*.gpg"
run_sh "rm -f /etc/apt/trusted.gpg.d/cuda*.gpg /etc/apt/trusted.gpg.d/nvidia*.gpg"

# ----------------------------------------------------------------------------
# 5. Remove residual install trees and config fragments.
# ----------------------------------------------------------------------------
echo "[5/9] Removing residual install trees and config files..."
run_sh "rm -rf /usr/local/cuda /usr/local/cuda-*"
run_sh "rm -rf /var/cuda-repo-* /var/cudnn-local-repo-*"
run_sh "rm -rf /usr/src/nvidia-*"
run_sh "rm -f  /etc/ld.so.conf.d/cuda*.conf /etc/ld.so.conf.d/nvidia*.conf"
run_sh "rm -f  /etc/profile.d/cuda*.sh /etc/profile.d/nvidia*.sh"
run_sh "rm -f  /etc/modprobe.d/nvidia*.conf"
run_sh "rm -f  /etc/OpenCL/vendors/nvidia.icd"

# Back up any xorg.conf that references the nvidia driver instead of deleting
# it outright — the user can inspect or restore manually.
if [ -f /etc/X11/xorg.conf ] && grep -qi 'nvidia' /etc/X11/xorg.conf 2>/dev/null; then
  echo "    /etc/X11/xorg.conf mentions nvidia — backing up to .nvidia-backup"
  run cp -a /etc/X11/xorg.conf /etc/X11/xorg.conf.nvidia-backup
  run rm -f /etc/X11/xorg.conf
fi

# ----------------------------------------------------------------------------
# 6. Drop any leftover NVIDIA DKMS module trees in a version-agnostic way.
# ----------------------------------------------------------------------------
echo "[6/9] Removing leftover NVIDIA DKMS modules..."
if [ -d /var/lib/dkms ]; then
  while IFS= read -r dkms_dir; do
    mod_name=$(basename "$dkms_dir")
    while IFS= read -r ver_dir; do
      mod_ver=$(basename "$ver_dir")
      echo "    -> dkms remove $mod_name/$mod_ver"
      run dkms remove "$mod_name/$mod_ver" --all || true
    done < <(find "$dkms_dir" -maxdepth 1 -mindepth 1 -type d ! -name 'kernel*')
  done < <(find /var/lib/dkms -maxdepth 1 -name 'nvidia*' -type d)
  run_sh "rm -rf /var/lib/dkms/nvidia* /var/lib/dkms/cuda*"
fi

# ----------------------------------------------------------------------------
# 7. (Optional) Purge unrelated third-party DKMS modules. OFF by default.
# ----------------------------------------------------------------------------
if [ "$PURGE_EXTRA_DKMS" -eq 1 ]; then
  echo "[7/9] Purging extra DKMS modules (--purge-extra-dkms)..."
  for mod_pkg in v4l2loopback-dkms rtl8812au-dkms 8188eu-dkms ax88179a-dkms; do
    run apt-get purge -y "$mod_pkg" || true
  done
  # Version-agnostic dkms cleanup
  for mod_name in rtl8812au 8188eu ax88179a v4l2loopback; do
    [ -d "/var/lib/dkms/$mod_name" ] || continue
    while IFS= read -r ver_dir; do
      mod_ver=$(basename "$ver_dir")
      run dkms remove "$mod_name/$mod_ver" --all || true
    done < <(find "/var/lib/dkms/$mod_name" -maxdepth 1 -mindepth 1 -type d ! -name 'kernel*')
  done
else
  echo "[7/9] Skipping third-party DKMS purge (use --purge-extra-dkms to opt in)."
fi

# ----------------------------------------------------------------------------
# 8. Purge `rc`-state packages that are clearly NVIDIA/CUDA related.
#    Scoped — does NOT touch unrelated rc packages.
# ----------------------------------------------------------------------------
echo "[8/9] Purging NVIDIA/CUDA leftover config (rc state) packages..."
RC_PKGS=$(dpkg -l 2>/dev/null | awk '/^rc/ {print $2}' \
  | grep -E '^(nvidia|libnvidia|cuda|libcudnn|libcublas|libcufft|libcurand|libcusolver|libcusparse|libnpp|libnccl|libnvjpeg|libnvinfer|libcutensor|tensorrt|xserver-xorg-video-nvidia)' || true)
if [ -n "$RC_PKGS" ]; then
  # shellcheck disable=SC2086
  run apt-get purge -y $RC_PKGS || true
else
  echo "    (no matching rc packages)"
fi

# ----------------------------------------------------------------------------
# 9. (Optional) Re-enable nouveau by removing its blacklist file and
#    rebuilding initramfs.
# ----------------------------------------------------------------------------
if [ "$RESTORE_NOUVEAU" -eq 1 ]; then
  echo "[9a/9] Restoring nouveau (--restore-nouveau)..."
  run_sh "rm -f /etc/modprobe.d/blacklist-nouveau.conf /etc/modprobe.d/nouveau-blacklist.conf"
  run update-initramfs -u || true
fi

# ----------------------------------------------------------------------------
# Final cache cleanup + ldconfig refresh.
# ----------------------------------------------------------------------------
echo "[9/9] apt autoremove + clean + ldconfig..."
run apt-get autoremove --purge -y || true
run apt-get clean
run ldconfig

echo "===================================================="
echo " Cleanup complete."
[ "$DRY_RUN" -eq 1 ] && echo " (DRY RUN — nothing was actually changed.)"
echo "===================================================="

# ----------------------------------------------------------------------------
# Reboot prompt — TTY-safe, restarts the display manager if the user declines.
# ----------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  exit 0
fi

if prompt_yes_no "Reboot now to finalize changes? (y/N):" "n"; then
  echo "Rebooting..."
  systemctl reboot
else
  echo "Skipping reboot."
  if [ -n "$ACTIVE_DM" ]; then
    echo "Restarting previously-active display manager: $ACTIVE_DM"
    systemctl start "$ACTIVE_DM" || true
  fi
  echo "Reminder: NVIDIA kernel modules that could not be unloaded will only"
  echo "be fully cleared after the next reboot."
fi
