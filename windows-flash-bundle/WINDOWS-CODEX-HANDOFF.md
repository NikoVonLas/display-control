# Handoff: Acer XV282K KV USB-hub firmware patch

Historical verification notes for the experimental Set-only V007 patch. The macOS application targets the V11 protocol.

## Established facts

- Exact original image size: 1,179,648 bytes (18 x 64-KiB banks).
- Original SHA-256:
  `7230e10cd846f99dd20ab0f8a3a29f0e50fcf551ce480f4adbed18d9a941ba35`
- Patched SHA-256:
  `646661738fa9b2c8d6dd5850140a9d8c32270675d21e3b18d7a8af7a252b7219`
- The offline patch changes only bank 2: the Set-VCP `EA` target at logical
  `E3A6-E3A7`, plus a 31-byte handler at `FF00-FF1E` in an erased code cave.
- `EA=0` selects USB-C/C-Type upstream; `EA=1` selects USB-B/B-Type upstream.
- Video input remains VCP `60` (`0F` DP, `10` USB-C, `11` HDMI1, `12` HDMI2).
- The handler was independently imported/decompiled and matches the intended
  `CF03.bit7` update path used by the monitor's OSD `USB Port Select` handler.
- The vendor updater writes 18 banks in reverse order, erases and programs
  256-byte pages through the last non-FF page, and uses a hardware CRC over the
  written range. It does not validate an embedded image signature/checksum.
- The patched bank 2 ends at `FF1E`, which the updater's page loop includes.
- The patched image has not yet been flashed to physical hardware.

## Required preflight

1. Run `VERIFY.ps1`; require `ALL FILES VERIFIED`.
2. Confirm a physical Windows machine, not a VM with USB passthrough.
3. Confirm direct USB-B connection with no dock/hub and OSD `USB Port Select`
   set to `B-Type`.
4. Confirm stable AC power for PC and monitor, Windows sleep disabled, and no
   pending reboot/update.
5. Confirm the updater folder contains its two DLLs.
6. Before any write, show the user the exact selected path and SHA-256 of
   `PATCHED_V007_USB_HUB_VCP_EA.bin` and ask for explicit final approval.

The original image is preserved as `ORIGINAL_V007.bin`. The vendor guide says
that after a successful update, monitor power must be unplugged and replugged.
On an updater error, it says to close the tool, power-cycle the monitor, and
retry. This is not a guarantee of recovery after every interrupted erase.
