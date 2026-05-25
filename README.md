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

- **[`recovery_manual.html`](recovery_manual.html)** — start-to-finish
  recovery guide for a failed 22.04 → 24.04 upgrade. Covers live-USB
  chroot, fixing broken packages, rewriting APT sources, fixing the GNOME
  desktop, and reinstalling CUDA / cuDNN.

- **[`REVIEW.md`](REVIEW.md)** — review of the previous versions of the
  script and manual, with a labelled list of every bug found and how it
  was fixed.

## Quick start

```bash
# Audit only — show what would be removed, change nothing.
sudo ./safe_clean_nvidia.sh --dry-run

# Real purge, interactive (asks to reboot at the end).
sudo ./safe_clean_nvidia.sh

# Non-interactive, also bring nouveau back.
sudo ./safe_clean_nvidia.sh --yes --restore-nouveau
```

Open `recovery_manual.html` in any browser for the full step-by-step
recovery procedure.
