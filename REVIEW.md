# Review: original NVIDIA purge script + Ubuntu 22.04→24.04 recovery manual

This document explains every concrete problem I found in the two artifacts
that were submitted for review, and how the corrected versions in this repo
address each one.

The corrected versions are:

- `safe_clean_nvidia.sh` — replacement for the bash purge script.
- `recovery_manual.html` — replacement for the HTML recovery manual,
  with the safe-purge script integrated as section 6.

---

## Part A — `safe_clean_nvidia.sh` (original)

### A1. Unrelated WiFi / USB-ethernet DKMS modules are hard-purged

Original step 5 unconditionally removes three third-party DKMS modules:

```bash
dkms remove 8188eu/5.3.9 --all 2>/dev/null || true
dkms remove ax88179a/3.5.0 --all 2>/dev/null || true
dkms remove rtl8812au/5.13.6-23 --all 2>/dev/null || true
```

Problems:

- These have nothing to do with NVIDIA or CUDA — they drive USB WiFi
  (`rtl8812au`, `8188eu`) and USB 3 Gigabit ethernet (`ax88179a`).
- On many laptops and headless boxes, removing them means **no networking
  after the next reboot**. That is the opposite of "safe".
- The versions are hard-coded (`5.3.9`, `3.5.0`, `5.13.6-23`) and will not
  match what is actually installed on a given system, so the command
  effectively does nothing on some hosts and silently nukes the driver on
  others.

Fix in `safe_clean_nvidia.sh`: third-party DKMS removal is now gated behind
an explicit `--purge-extra-dkms` flag, and when enabled it is
version-agnostic (it iterates whatever versions exist in
`/var/lib/dkms/<mod>/`).

### A2. NVIDIA kernel modules are never unloaded before purge

The original goes straight to `apt-get purge` without trying to drop the
loaded `nvidia`, `nvidia_drm`, `nvidia_modeset`, `nvidia_uvm`, and
`nvidia_peermem` modules. apt will still remove the files, but the running
kernel keeps the old modules pinned until reboot. If the user picks "n" at
the reboot prompt, the system is in a half-broken state.

Fix: step 2 of the new script unloads each module via `modprobe -r` if it
is currently in `lsmod`. If unloading fails (because something is still
using the device) the script keeps going and reminds the user at the end.

### A3. CUDA / cuDNN coverage is incomplete

The original purge list:

```bash
apt-get purge -y '^nvidia-.*' '^libnvidia-.*' '^cuda-.*' '^libcudnn.*' '*cublas*' '*cufft*'
```

Missing companion packages that NVIDIA ships alongside CUDA and that are
routinely installed on ML / GPU machines:

- `libcurand*`, `libcusolver*`, `libcusparse*`
- `libnpp*` (NVIDIA Performance Primitives)
- `libnccl*` (multi-GPU collective comms)
- `libnvjpeg*`
- `libnvinfer*` and `tensorrt*` (TensorRT)
- `libcutensor*`
- `xserver-xorg-video-nvidia*` (Xorg DDX, not matched by `^nvidia-.*`)

Fix: the new script enumerates an explicit, anchored ERE list covering all
of the above plus a bare `^cuda$` (in case the meta-package "cuda" is
installed without a dash).

### A4. `'*cublas*'` and `'*cufft*'` are not portable patterns

apt-get accepts these on current versions because it falls back to a
glob-like match, but a leading `*` is technically not a valid POSIX ERE
quantifier and there is no guarantee future apt releases will keep that
behaviour. The new script uses anchored EREs (`^libcublas.*`,
`^libcufft.*`) which are unambiguous on every apt version.

### A5. `rc`-state purge is too broad

```bash
dpkg -l | grep '^rc' | awk '{print $2}' | xargs -r apt-get purge -y
```

This removes **every** package in `rc` state, not just NVIDIA / CUDA ones.
If the user previously uninstalled (but did not purge) something
unrelated — say `mysql-server` or `nginx` — their config files are gone
too, with no warning.

Fix: in the new script, the `rc` purge is filtered with a regex that
matches only NVIDIA / CUDA / cuDNN / TensorRT / Xorg-nvidia package
families.

### A6. `read -p` is not pipe-safe

If the script is invoked via `curl ... | sudo bash` (a common pattern),
stdin is the pipe, not the terminal, and the reboot prompt either consumes
garbage or hangs forever.

Fix: the new prompt helper reads from `/dev/tty` when stdin is not a
terminal, and falls back to a default when no TTY is available at all. It
also honours a new `-y` / `--yes` flag for non-interactive use.

### A7. Display managers are stopped but never restarted

If the user answers "n" to the reboot prompt, the script leaves them with
gdm3 / sddm / lightdm stopped — no graphical login.

Fix: the new script records which display manager (if any) was actually
active, and `systemctl start`s it back on a "no, do not reboot" answer.

### A8. Leftover config dirs are not cleaned

The original removes `/usr/local/cuda*`, `/var/cuda*`, and
`/usr/src/nvidia-*` but leaves these behind:

- `/etc/ld.so.conf.d/cuda*.conf` and `/etc/ld.so.conf.d/nvidia*.conf`
  — these keep pointing the dynamic linker at directories that no longer
  exist, producing `ldconfig` warnings forever.
- `/etc/profile.d/cuda*.sh` and `/etc/profile.d/nvidia*.sh`
  — every shell login then exports `PATH` / `LD_LIBRARY_PATH` entries
  pointing at deleted directories.
- `/etc/modprobe.d/nvidia*.conf` — module options for hardware that no
  longer has a driver.
- `/etc/OpenCL/vendors/nvidia.icd` — the OpenCL ICD loader keeps trying
  to load the missing `libnvidia-opencl.so`.
- `/etc/X11/xorg.conf` — if it was generated by `nvidia-xconfig`, it now
  references a driver that does not exist, which can break the next X
  start even on a non-NVIDIA driver.

Fix: the new script removes all of the above, and the `xorg.conf` case is
handled defensively (backed up to `xorg.conf.nvidia-backup` before
removal, and only touched if it actually mentions "nvidia").

### A9. Repo signing keys may be left in two different locations

CUDA / NVIDIA installers historically dropped signing keys in either
`/usr/share/keyrings/` (current pattern) or `/etc/apt/trusted.gpg.d/`
(legacy). The original only cleans the former.

Fix: the new script cleans both.

### A10. Nouveau is implicitly left blacklisted

When the NVIDIA proprietary driver is installed, an installer typically
drops `/etc/modprobe.d/blacklist-nouveau.conf`. Purging the driver does
not remove that file, so on next boot **no** GPU driver loads (nouveau is
still blacklisted, proprietary is gone). The user is left with a software
framebuffer and broken Wayland.

Fix: the new script does not delete this file by default (the user might
want it gone, might not), but exposes a `--restore-nouveau` flag that
removes the blacklist and runs `update-initramfs -u` so nouveau actually
loads on next boot.

### A11. No `ldconfig`, no dry-run, no logging of what is being run

Minor quality-of-life issues. The new script:

- runs `ldconfig` at the end so the dynamic linker cache no longer
  references removed CUDA libraries;
- supports `--dry-run` so the user can audit the exact commands before
  they execute;
- prints every command it runs prefixed with `+ `, so the output of a
  real run reads like a transcript.

### A12. `set -uo pipefail` would have caught silent typos

The original has no shell options set. The new script uses
`set -uo pipefail` — strict enough to catch unset-variable bugs and
silently-failing pipelines, but **not** `set -e`, because we explicitly
want individual `apt-get purge` failures to be non-fatal (the goal is to
keep cleaning).

---

## Part B — HTML recovery manual (original)

### B1. Section 1 chroot recipe omits the EFI / /boot mounts

The original bind-mounts `/dev /proc /sys /run` but never:

- mounts a separate `/boot` partition inside the chroot if one exists, and
- mounts the EFI System Partition at `/mnt/boot/efi`.

If you run `grub-install`, `update-grub`, or `update-initramfs` inside the
chroot without those mounts, the EFI bootloader files do not get rewritten
and the system can still fail to boot afterwards.

The corrected manual adds explicit `mount /dev/sdXZ /mnt/boot` and
`mount /dev/sdXW /mnt/boot/efi` steps with a clear note about when they
apply.

### B2. Section 1 omits `/dev/pts` and assumes a plain ext4 root

Two issues:

- Interactive subprocesses (vi, `passwd`, anything that opens a pty) need
  `/dev/pts` bind-mounted inside the chroot. The original does not mount
  it.
- LVM, LUKS, and Btrfs roots all need extra setup before
  `mount /dev/sdXY /mnt` works. The original gives the reader no warning,
  so somebody with a LUKS root will type the command, get
  `unknown filesystem type "crypto_LUKS"`, and be stuck.

Fixed: the corrected manual bind-mounts `/dev/pts`, and a warning callout
spells out the LVM / LUKS / Btrfs caveats.

### B3. Section 2 hard-purges WiFi / USB-ethernet / virtual-camera DKMS

Same issue as A1 above — the original `apt remove --purge` line bundles
`rtl8812au-dkms`, `8188eu-dkms`, `ax88179a-dkms`, and
`v4l2loopback-dkms` into one command. On laptops with a USB WiFi
adapter or USB-ethernet, that single command kills networking.

Fixed: the corrected manual lists what each of those drivers actually
does, tells the reader how to check whether they are in use
(`lsmod | grep`, `lsusb`), and only then suggests removing the ones they
do not need, one at a time.

### B4. Section 3 instructs the reader to restore the wrong `sources.list`

The original says:

```
mv /etc/apt/sources.list.distUpgrade /etc/apt/sources.list
```

`/etc/apt/sources.list.distUpgrade` is the **pre-upgrade backup** of the
jammy sources, written by `do-release-upgrade` before it starts. Moving
it back on top of the current sources will silently pin the system to
jammy. The subsequent `sed 's/jammy/noble/g'` runs only against
`sources.list.d/*.list` and `sources.list.d/*.sources`, so the freshly
restored jammy `sources.list` never gets rewritten.

This is the single biggest functional bug in the original manual.

Fixed: the corrected manual:

- Does not restore the `.distUpgrade` file at all.
- Backs up the current sources to `/root/apt-backup-YYYYMMDD/` first.
- Rewrites `/etc/apt/sources.list.d/ubuntu.sources` (Ubuntu 24.04's
  primary deb822 file, which the original ignores entirely) **and**
  the legacy `/etc/apt/sources.list`.
- Warns the reader not to blindly `sed jammy→noble` against third-party
  PPAs — many third-party repos do not yet have a noble release, and
  silently rewriting them produces 404s and broken updates.

### B5. Section 3 ignores Ubuntu 24.04's deb822 sources

On a fresh 24.04 install the primary apt sources live in
`/etc/apt/sources.list.d/ubuntu.sources` (deb822 format), and
`/etc/apt/sources.list` is empty or absent. The original manual never
mentions this file, so the `sed` step misses it.

Fixed: the corrected manual rewrites `ubuntu.sources` first.

### B6. Section 4 unmount sequence misses `/dev/pts` and is not recursive

`umount /mnt/dev` will fail if `/mnt/dev/pts` is still mounted. The
original lists the four bind-mounts in the right order but never accounts
for `/dev/pts`, and if section 1 is followed literally the unmount
command will refuse to run.

Fixed: the corrected manual uses `sudo umount -R /mnt`, which handles
arbitrary nested mounts in the right order, and shows `lsof +D /mnt` /
`fuser -vm /mnt` for the case where a mount is still busy.

### B7. Section 5 calls a `gnome-extensions` subcommand that does not exist

`gnome-extensions reset -q` is not a real subcommand. `gnome-extensions`
supports `enable`, `disable`, `info`, `list`, `prefs`, `create`, and
`uninstall`. Running the original command prints:

```
gnome-extensions: error: argument {help,version,enable,disable,info,...}: invalid choice: 'reset'
```

…and does nothing. The double-panel / ghost-dock problem the section
claims to fix is not fixed.

Fixed: the corrected manual resets extension state with the correct tools:

```bash
gsettings set org.gnome.shell enabled-extensions "[]"
gsettings set org.gnome.shell disabled-extensions "[]"
dconf reset -f /org/gnome/shell/extensions/
```

### B8. Section 5 suggests restarting `gdm` under Wayland

`sudo systemctl restart gdm` kills the user's Wayland compositor mid-flight
and can leave per-user systemd units (and the user dbus) in a wedged
state. On 22.04+ where Wayland is the default, the safer instruction is
"log out", or from a TTY `loginctl terminate-user "$USER"`.

Fixed: the corrected manual replaces the `restart gdm` line with an
explicit log-out instruction.

### B9. Section 6 hard-codes a future CUDA version

The original says "Set CUDA 13.1 as default". At time of writing, CUDA 13
is not the current public release; copy-pasting `cuda-13.1` paths will
fail on most readers' systems. More importantly, the `wget` URL for
cuDNN 9.5.1 is hard-coded — NVIDIA rotates that filename per release, so
this line will 404 within months.

Fixed: section 7 of the corrected manual:

- Tells the reader to go to NVIDIA's CUDA / cuDNN download page and copy
  the exact commands NVIDIA shows for the version they want.
- Parameterises the cuDNN version (`CUDNN_VER=9.5.1`) and explains how to
  spot a wrong version (the `wget` 404s).
- Warns that the original example version may be out of date.

### B10. Section 6 appends to `~/.bashrc` non-idempotently

```bash
echo 'export PATH=...' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH=...' >> ~/.bashrc
```

Run the manual twice (which people do, when something does not work the
first time) and `~/.bashrc` now has duplicate exports. After three or
four reinstalls this becomes a maintenance problem.

Fixed: section 7 of the corrected manual installs a single
`/etc/profile.d/cuda.sh` file that prepends `/usr/local/cuda/bin` and
`/usr/local/cuda/lib64` only if they are not already present. Re-running
the install command is a no-op.

### B11. Section 6 does the cleanup that section 6-in-the-new-manual now does

The original mixes a half-hearted cuDNN cleanup
(`rm -f /etc/apt/sources.list.d/*cudnn*`, etc.) into the reinstall
section. That is the wrong place — cleanup belongs in the purge step.

Fixed: cleanup of CUDA / cuDNN apt sources, keys, residual install trees,
ld.so.conf fragments, and OpenCL ICD entries is centralised in section 6
of the new manual (the `safe_clean_nvidia.sh` script).

### B12. No final `ldconfig`

Section 7 of the original ends with `apt --fix-broken install` and a
reboot. Several of the package operations above shuffle shared-library
locations; running `ldconfig` afterwards is cheap insurance against a
stale linker cache.

Fixed: the new section 8 ends with `sudo ldconfig` before the reboot.

---

## Summary of fixes

| # | Original problem | Fix in this repo |
|---|---|---|
| A1 | Unrelated WiFi / USB-ethernet DKMS purged unconditionally | Gated behind `--purge-extra-dkms` |
| A2 | NVIDIA modules never unloaded before purge | `modprobe -r` step before purge |
| A3 | CUDA companion libs missing from purge list | Explicit ERE list covers them |
| A4 | `'*cublas*'` non-portable pattern | Anchored EREs |
| A5 | Blanket `rc`-state purge | Filtered to NVIDIA / CUDA families |
| A6 | `read -p` hangs on piped invocation | Reads from `/dev/tty`, plus `--yes` flag |
| A7 | Display manager stopped, never restarted | Restored on "no, do not reboot" |
| A8 | Leftover `/etc/{ld.so.conf.d,profile.d,modprobe.d,X11,OpenCL}` configs | All cleaned, xorg.conf backed up |
| A9 | Only one of two keyring locations cleaned | Both cleaned |
| A10 | Nouveau left blacklisted after purge | `--restore-nouveau` flag |
| A11 | No `ldconfig`, no `--dry-run`, no logging | All three added |
| A12 | No shell strictness | `set -uo pipefail` |
| B1 | Missing EFI / `/boot` mounts in chroot | Explicit step + note |
| B2 | Missing `/dev/pts`, LVM/LUKS/Btrfs not flagged | Added |
| B3 | Hard-purges WiFi / USB-eth / v4l2loopback in chroot | Diagnostics first, opt-in removal |
| B4 | Restores `sources.list.distUpgrade` (= old jammy backup) | Removed; correct rewrite path documented |
| B5 | Ignores deb822 `ubuntu.sources` on 24.04 | Handled |
| B6 | Unmount sequence misses `/dev/pts` and is not recursive | `umount -R /mnt` |
| B7 | `gnome-extensions reset` is not a real subcommand | `gsettings` + `dconf reset` |
| B8 | `systemctl restart gdm` under Wayland | Log out / `loginctl terminate-user` |
| B9 | Hard-coded future CUDA version + brittle cuDNN URL | Parameterised, version-agnostic |
| B10 | `~/.bashrc` non-idempotent appends | Idempotent `/etc/profile.d/cuda.sh` |
| B11 | Cleanup mixed into reinstall section | Centralised in purge section (script) |
| B12 | No final `ldconfig` | Added |
