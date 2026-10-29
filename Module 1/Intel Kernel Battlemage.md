# Intel Kernel Battlemage: Ubuntu 24.04 Driver Remediation

Use this guide only when an Intel Arc Pro Battlemage GPU is visible through PCIe but does not bind to the Linux `xe` driver.

Return to the Module 1 `README.md` after the driver is working.

## 1. Confirm the Failure State

```bash
lspci | grep -Ei 'vga|display'
```

Check each Intel GPU:

```bash
lspci -k -s 18:00.0
lspci -k -s 54:00.0
```

If the Intel devices are present but this line is missing:

```text
Kernel driver in use: xe
```

continue with this remediation guide.

## 2. Record the Current Kernel and OS

```bash
uname -r
```

```bash
lsb_release -a
```

The validated workshop remediation path used Ubuntu 24.04 with the Intel Multi-Arc Battlemage offline driver package and Intel kernel `6.17.0-1009-intel`.

## 3. Obtain the Multi-Arc Offline Installer

Download the Intel Multi-Arc Battlemage offline installer through the approved Intel download page and accept the applicable software license agreement.

Validated package:

```text
multi-arc-bmg-offline-installer-26.39.10.2-combo
```

Transfer the package to the server if necessary.

After extraction, enter the installer directory:

```bash
cd ~/multi-arc-bmg-offline-installer-26.39.10.2-combo
```

Inspect it:

```bash
ls -lah
```

Expected installer files include:

```text
installer.sh
install
uninstall
README.md
VERSION
```

## 4. Run the Installer

```bash
sudo ./installer.sh
```

If the installer completes successfully, proceed to the reboot section.

## 5. Repair Ubuntu Package Dependencies if Required

Check package state:

```bash
sudo dpkg --audit
```

```bash
sudo apt-get check
```

If APT reports broken dependencies:

```bash
sudo apt --fix-broken install
```

Verify again:

```bash
sudo dpkg --audit
sudo apt-get check
```

Both checks should complete without package errors before rebooting.

## 6. Confirm the Intel Kernel Is Installed

```bash
ls /boot/vmlinuz*
```

For the validated workshop configuration, the target kernel was:

```text
6.17.0-1009-intel
```

## 7. Reboot

Before rebooting a remote system, ensure that remote access will return after boot.

Then:

```bash
sudo reboot
```

Reconnect and verify:

```bash
uname -r
```

Expected for the validated environment:

```text
6.17.0-1009-intel
```

## 8. Verify `xe` Driver Binding

```bash
lspci -k -s 18:00.0
lspci -k -s 54:00.0
```

Each Intel GPU should report:

```text
Kernel driver in use: xe
Kernel modules: xe
```

## 9. Verify DRM Render Nodes

```bash
ls -l /dev/dri
```

Intel compute render nodes should now be present, for example:

```text
renderD128
renderD129
```

Check PCI mapping:

```bash
ls -l /dev/dri/by-path
```

## 10. Verify XPU-SMI

```bash
xpu-smi discovery
```

If XPU-SMI only works with `sudo`, add the current user to the GPU access groups:

```bash
sudo usermod -aG render,video $USER
```

Log out and reconnect.

Then verify:

```bash
groups
xpu-smi discovery
```

## 11. Return to Module 1

Once all Intel GPUs report:

```text
Kernel driver in use: xe
```

and XPU-SMI successfully discovers the GPUs, return to `README.md` and continue from **Part 2: Validate the DRM Devices**.
