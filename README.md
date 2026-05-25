# ubntu-clean-start

Tools for cleaning up old drivers, configs, and DKMS modules after a Ubuntu
upgrade — specifically a 22.04 (jammy) → 24.04 (noble) `do-release-upgrade`
that left the system in a half-broken state.

## Contents

- **[`safe_clean_nvidia.sh`](safe_clean_nvidia.sh)** — headless-safe purge of
  NVIDIA / CUDA / cuDNN / TensorRT packages, signing keys, apt sources,
  residual install trees, ld.so / profile / modprobe / X11 fragments, and
  leftover DKMS modules. Safe to run over SSH. Supports `--dry-run`,
  `--restore-nouveau`, `--purge-extra-dkms`, and `--yes`.

- **[`driver-install.sh`](driver-install.sh)** — wrapper around the upstream
  NVIDIA `.run` installer. Auto-detects the .run file, generates and
  enrols a Machine Owner Key for Secure Boot, picks open vs. proprietary
  kernel modules based on GPU generation, and guides you through dropping
  to a TTY before swapping the running driver.

- **[`fix_nvidia_gui_v2.sh`](fix_nvidia_gui_v2.sh)** — swaps Ubuntu's
  apt-shipped `nvidia-settings` and matching `libnvidia-gtk{2,3}` for the
  versions extracted from the .run installer (the well-known
  "double free or corruption" crash workaround). Uses `dpkg-divert` and
  `apt-mark hold` so apt cannot silently undo it, and ships a working
  `revert` path.

- **[`recovery_manual.html`](recovery_manual.html)** — start-to-finish
  recovery guide for a failed 22.04 → 24.04 upgrade. Covers live-USB
  chroot, fixing broken packages, rewriting APT sources, fixing the GNOME
  desktop, booting to terminal-only mode (GRUB / systemd target 3),
  reinstalling the NVIDIA driver with MOK signing, and reinstalling
  CUDA / cuDNN.

- **[`REVIEW.md`](REVIEW.md)** — review of the previous versions of the
  scripts and manual, with a labelled list (A–E) of every bug found and
  how it was fixed.

## Quick start

Cleanup of an old NVIDIA / CUDA install:

```bash
# Audit only — show what would be removed, change nothing.
sudo ./safe_clean_nvidia.sh --dry-run

# Real purge, interactive (asks to reboot at the end).
sudo ./safe_clean_nvidia.sh

# Non-interactive, also bring nouveau back.
sudo ./safe_clean_nvidia.sh --yes --restore-nouveau
```

Fresh driver install with Secure Boot + MOK signing (drop the .run file in
the current directory first):

```bash
# First-time MOK setup, then reboot to enrol in MokManager.
sudo ./driver-install.sh --setup-mok

# After enrolment, install the driver.
sudo ./driver-install.sh
```

If Ubuntu's `nvidia-settings` crashes with "double free or corruption":

```bash
sudo ./fix_nvidia_gui_v2.sh install   # auto-detects .run in current dir
sudo ./fix_nvidia_gui_v2.sh status
sudo ./fix_nvidia_gui_v2.sh revert    # cleanly restores apt-shipped files
```

Open `recovery_manual.html` in any browser for the full step-by-step
recovery procedure.
