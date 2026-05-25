# Review: original NVIDIA purge script + Ubuntu 22.04→24.04 recovery manual

This document explains every concrete problem I found in the two artifacts
that were submitted for review, and how the corrected versions in this repo
address each one.

The corrected versions are:

- `safe_clean_nvidia.sh` — replacement for the bash purge script.
- `recovery_manual.html` — replacement for the HTML recovery manual,
  with the safe-purge script integrated as section 6.
- `driver-install.sh` — replacement for the NVIDIA .run installer wrapper
  that signs the kernel module with a Machine Owner Key.
- `fix_nvidia_gui_v2.sh` — replacement for the script that works around the
  Ubuntu `nvidia-settings` "double free" crash.

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

---

## Part C — `driver-install.sh` (original)

### C1. Hard-coded driver filename and version

The original hard-codes `NVIDIA-Linux-x86_64-595.71.05.run` as both the
filename and the implicit version. Anyone with a different driver release
has to edit the script. Worse, there is no check that the file exists
before `sudo` is invoked — if it is missing, `sudo` prompts for a
password, then the run silently `command not found`s.

Fix: the new script either accepts the .run path as an argument or
auto-detects `./NVIDIA-Linux-*.run`. It refuses to continue if there is no
match, or if there are multiple matches and the user did not disambiguate.

### C2. No verification of MOK key / certificate before running

The original passes `--module-signing-secret-key=/root/module-signing/MOK.key`
straight to the installer without checking whether that file exists. If
it does not, the NVIDIA installer aborts halfway through, leaving the
system with a partially-installed driver (the userland is replaced; the
kernel module never finishes building).

Fix: the new script verifies that both the key and the certificate exist
before invoking the installer. If they do not, it offers to generate a
fresh keypair with `openssl req`, written to `/root/module-signing/` with
the correct permissions.

### C3. No MOK enrolment guidance — signed-but-not-trusted modules

This is the biggest functional gap in the original. Signing a kernel
module with a key that is not enrolled in shim's MOK list produces a
module the kernel refuses to load under Secure Boot. The driver appears
to install fine, then `nvidia-smi` fails with `NVIDIA-SMI has failed
because it couldn't communicate with the NVIDIA driver` and `dmesg`
shows `Loading of unsigned module is rejected` or `module verification
failed`. The original script never mentions `mokutil --import`, never
checks whether the MOK is already enrolled, and never explains the blue
MokManager screen that appears on the next reboot.

Fix: the new script:
- detects Secure Boot state with `mokutil --sb-state`;
- if SB is enabled, runs `mokutil --test-key` to see if the MOK is
  already enrolled;
- if it is not, prints a clear walk-through and offers to run
  `mokutil --import` for the user (which schedules enrolment for the
  next reboot);
- exits cleanly after scheduling enrolment, telling the user to reboot,
  complete enrolment in MokManager, then rerun the script.

### C4. `--kernel-module-type=open` is used unconditionally

The open kernel modules only support Turing (RTX 20-series, GTX 16-series)
and newer. On Pascal (10-series), Maxwell (9-series), or Kepler hardware
the installer prints a confusing error and exits. The original always
passes `--kernel-module-type=open`.

Fix: the new script reads `lspci`, matches the GPU name against the known
set of architectures that support open modules, and picks the right
module type automatically. The user can override with
`--open` or `--proprietary`.

### C5. Inconsistent sudo / root handling

The original is meant to be run as a regular user (it uses `sudo` inside),
but several of its commands (`sudo ./NVIDIA...run`, `sudo apt update`,
`sudo chmod ...`) prompt for sudo on every other line, which breaks
non-interactive use. There is also no `EUID` check; if the user happens
to invoke it with `sudo`, the inner `sudo` calls become redundant.

Fix: the new script requires EUID 0 and drops every inner `sudo`. One
authentication point at the entry, not five.

### C6. `read -p` under `set -e` is a foot-gun, and not TTY-safe

The original script enables `set -e` then calls `read -p "Press Enter..."`
at two places. If the script is piped (e.g. `curl ... | sudo bash`)
`read` returns failure on the closed stdin, which `set -e` interprets as
a fatal error and exits before the install ever runs. Even on a TTY,
running the script via `sh -c '... | tee log.txt'` produces the same
symptom.

Fix: the new script does not use `set -e`. Its `pause()` and `ask_yn()`
helpers explicitly read from `/dev/tty` when stdin is not a terminal, and
fall through cleanly when no TTY is available at all.

### C7. Display server is not actually stopped

The original tells the user to run
`sudo systemctl isolate multi-user.target` in another terminal and then
waits for them to press Enter. That works in theory; in practice, the
user does not always know what "runlevel 3" / "multi-user target" means,
or how to get back. Worse, the script offers no help if the user is in
that exact situation already (over SSH, on a headless box) and there is
nothing to isolate.

Fix: the new script:
- detects whether `graphical.target` is currently active;
- if it is, prints a short explanation of the three ways to drop to a
  TTY — one-shot via GRUB, permanent via
  `systemctl set-default multi-user.target`, or right-now via
  `systemctl isolate multi-user.target`;
- offers to do the `systemctl isolate` for them;
- after install, if it is sitting in `multi-user.target`, prints how to
  get the desktop back.

The matching long-form walk-through lives in section 7 of
`recovery_manual.html`.

### C8. `apt --reinstall install nvidia-settings` conflicts with v2

Step 4 of the original runs
`sudo apt --reinstall install nvidia-settings`. On systems where the
broken-`nvidia-settings` workaround in `fix_nvidia_gui_v2.sh` has already
been applied, this command silently undoes the workaround — apt restores
the crashing 510/590 binary on top of our diversion.

Fix: the new script no longer reinstalls `nvidia-settings` by default.
It prints a small section at the end explaining that the .run installer
already dropped a working binary, and that the user should only run
`apt-get install --reinstall nvidia-settings` if they prefer the apt
version. There is also an explicit link to `fix_nvidia_gui_v2.sh` for
systems where the apt version is the broken one.

### C9. `apt --reinstall install` is plain `apt` and missing `-y`

Plain `apt` is documented as not stable-for-scripts and will print
`WARNING: apt does not have a stable CLI interface` on every run. It is
also missing `-y`, so the script will block on a confirmation prompt.

Fix: the new script uses `apt-get install --reinstall -y nvidia-settings`
(only in the documented optional follow-up).

### C10. No log file, no `nvidia-installer.log` hint on failure

If the .run installer fails, the original `error` function only prints
"NVIDIA .run installer failed." and exits. The actual cause is in
`/var/log/nvidia-installer.log`, which the user has to know about.

Fix: the new script prints the path of the installer log on any failure.

### C11. Polkit fix is correct but trivially incomplete

The `screen-resolution-extra` polkit wrapper at
`/usr/share/screen-resolution-extra/nvidia-polkit` needs to be
executable for the GUI to save configuration without sudo. The original
gets this right. The new script preserves the fix; no change.

---

## Part D — `fix_nvidia_gui_v2.sh` (original)

### D1. Silently overwrites apt-managed files

The original `cp $EXTRACT_DIR/nvidia-settings /usr/bin/nvidia-settings`
clobbers a file that is owned by the `nvidia-settings` package. Any
future `apt install --reinstall nvidia-settings`,
`apt-get install -f`, or even an unattended-upgrades run can restore the
broken Ubuntu file over our fix without warning.

Fix: the new script uses `dpkg-divert --add --rename --divert
/usr/bin/nvidia-settings.distrib /usr/bin/nvidia-settings`, which moves
the apt-shipped binary aside and registers the diversion in the dpkg
database. apt is now structurally unable to overwrite our copy without
first removing the diversion.

### D2. Pin priority -1 is the wrong tool

The original creates
`/etc/apt/preferences.d/pin-nvidia-settings` with
`Pin-Priority: -1`. That syntax bars the package from any apt source,
but the package is already installed — pinning does not remove it, and
does not stop `apt-mark auto` reasoning from removing the binary as a
side-effect of an unrelated upgrade. It also produces confusing
`apt policy` output that surprises people who later try to install a
different NVIDIA package.

Fix: the new script uses `apt-mark hold nvidia-settings` instead. That
is the documented "do not upgrade or remove this package" mechanism,
and it composes correctly with the dpkg-divert approach.

### D3. Hard-coded `${base}.590.44.01` compatibility symlink

The original creates a symlink named
`libnvidia-gtk2.so.590.44.01` for one specific broken Ubuntu version.
On any other Ubuntu host, that symlink is dead weight pointing at a
version of the library that the system does not need; on the exact
broken Ubuntu, it is required.

Fix: the new script does not create this symlink unconditionally. It
builds the unversioned (`libnvidia-gtkN.so`) symlink only, and the
comment block documents how to add a version-specific compat link if a
specific binary on the system actually needs it.

### D4. `do_revert` does not actually revert the library overwrite

The original `revert` removes only the apt pin file and runs
`apt --reinstall install nvidia-settings`. The custom `.so` files we
copied into `/usr/lib/x86_64-linux-gnu/` remain. The symlinks we created
remain. ldconfig is never refreshed. After "revert", the system is
still running our libraries.

Fix: the new script tracks every file it touches in
`/var/lib/fix_nvidia_gui_v2.state` and walks them in `revert`. The
dpkg-divert mechanism makes this trivial: `dpkg-divert --remove --rename`
on each target restores the distribution file in one atomic step. After
that, the script runs `apt-mark unhold`, refreshes ldconfig, and
reinstalls the apt package to make sure every file is back to its
package-shipped state.

### D5. No `set` discipline, no extract-failure check

The original has no shell options set and does not check whether
`--extract-only` succeeded. If the .run file is missing or corrupt the
script continues with an empty `$EXTRACT_DIR` and produces a stream of
`cp: cannot stat` errors before completing "successfully."

Fix: the new script uses `set -uo pipefail`, gates every step with
explicit `[ -f ... ] || die`, and traps EXIT to clean up the temporary
extract directory whether the run succeeded or failed.

### D6. No status / diagnostics subcommand

The original has `install` / `revert` only. Anyone trying to debug "did
I run this script on this box?" has to grep for the pin file by hand.

Fix: the new script adds a `status` subcommand that lists which paths
are currently diverted, whether `nvidia-settings` is held, and what is
in the state file.

### D7. Version detection regex is fine but fragile

`grep -oP '\d+\.\d+\.\d+'` matches the first three-dot-version in the
filename. It works on `NVIDIA-Linux-x86_64-595.71.05.run`, but on a
filename like `NVIDIA-12-Linux-x86_64-595.71.05.run` it would pick the
wrong group.

Fix: the new script anchors on `basename` and uses an `[0-9]+` ERE; minor
robustness improvement, not a security issue.

---

## Part E — additions to `recovery_manual.html` requested mid-review

### E1. Boot to terminal-only mode (TTY / GRUB / runlevel 3)

The manual previously had no section explaining how to boot to a TTY,
which is a prerequisite for installing the NVIDIA driver from a .run
file. Section 7 of the new manual covers all four practical paths:

1. One-shot edit at the GRUB menu (append `3` or
   `systemd.unit=multi-user.target` to the `linux ...` line, press
   Ctrl-X).
2. Permanent default = TTY via `sudo systemctl set-default
   multi-user.target`.
3. Permanent via `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`,
   followed by `update-grub`.
4. Right-now via `sudo systemctl isolate multi-user.target`, with a
   matching `isolate graphical.target` to come back.

Each option lists how to undo it, plus the warning that option 4 will
kill the current graphical session immediately (so save your work).

### E2. Sections 8 and 10 documenting the new scripts

The manual now has dedicated sections describing `driver-install.sh`
and `fix_nvidia_gui_v2.sh`, with the same caveats called out in the
scripts themselves (Secure Boot / MOK enrolment, GPU generation check,
the conflict between `apt --reinstall nvidia-settings` and the v2
diversion).

---

## Part F — post-merge bugfixes from Devin Review on PR #2

These are bugs in the version of `driver-install.sh` that landed in
`main` via PR #2 and were caught by Devin Review afterwards. They are
fixed in the follow-up PR.

### F1. `ensure_mok_enrolled` fell through when the user declined enrolment

Original behaviour (post-merge): if Secure Boot was on and the MOK was
not yet enrolled, `ensure_mok_enrolled()` would offer to run
`mokutil --import` and, on a "yes" answer, schedule enrolment and exit
cleanly. But if the user answered "no" — or if there was no TTY at all,
in which case `ask_yn` returned the default "n" — the function silently
returned and the script continued straight into the NVIDIA installer.
The installer then signed the modules with a key the kernel does not
trust, the install completed "successfully," and on the next reboot
`modprobe nvidia` was rejected with a `module verification failed`
message in `dmesg`. The user ended up with a half-installed driver and
no `nvidia-smi`.

Fix: after the "would you like to enrol now?" prompt, if the user did
not accept (or there is no TTY), `die` loudly with the exact
`sudo mokutil --import …` command needed. The script never reaches the
installer with an un-enrolled MOK.

### F2. `systemctl get-default` checked the wrong target

Original behaviour: at the end of the script we printed a "you are now
in TTY mode, here is how to get the desktop back" reminder, guarded by
`systemctl get-default | grep -q multi-user`. The problem is that
`get-default` reads `/etc/systemd/system/default.target`, which is the
**persistent** default target. If the script switched the running
session to `multi-user.target` via `systemctl isolate`, the persistent
default symlink was unchanged (`graphical.target`), so the reminder was
suppressed exactly when the user needed it the most.

Fix: gate the reminder on `! systemctl is-active graphical.target` —
that reflects the *currently running* state, not the boot-time default.
A comment block in the script explains the distinction.

### F3. Limited-BIOS-ROM motherboards (ASRock Z170 PG)

User-reported issue, not a Devin Review finding. Section 8 of the
recovery manual now covers disabling the kernel microcode loader on
boards whose BIOS chip is too small to hold a current Intel microcode
revision (the canonical Z170 case). Three documented paths:

1. Kernel command line `dis_ucode_ldr` via
   `/etc/default/grub` + `update-grub`.
2. `apt purge intel-microcode iucode-tool` + `update-initramfs -u`.
3. Pin a known-good `intel-microcode` version via
   `apt install intel-microcode=<v>` + `apt-mark hold`.

Each option has an "undo" recipe. The section also calls out the
security tradeoff: disabling microcode loading removes Spectre / L1TF /
MDS / Downfall / INCEPTION mitigations that depend on a recent
microcode revision.
