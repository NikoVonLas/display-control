# Acer XV282K KV firmware research

This directory contains read-only analysis tools and an offline patch for the
exact Acer XV282K KV V007 firmware image. Nothing here flashes the monitor.

This is the historical Set-only prototype. The macOS app requires the V11 Get/Set protocol, whose USB routing values are reversed.

## USB hub upstream finding

The monitor's System menu dispatch table starts at bank 11, address `827B`.
State `0x81` is row 7 and is the `USB Port Select` item. Its handler is
bank 11, address `EC4E`.

The handler stores the selection in `CF03.bit7`, marks the OSD data dirty, and
calls the common thunk at `30EC`. That thunk enters bank 16 at `DDB6` and
updates the Type-C state. The only reader of `CF03.bit7` is bank 9 at `CB88`;
its result is written to bit 2 of the per-port Type-C status. In Realtek's
reference source that bit is `_TYPE_C_HUB_INPUT_SWITCH_CHG`.

The value mapping follows Realtek's `EnumHubInputPort`:

- `0`: Type-C / C-Type upstream
- `1`: non-Type-C / B-Type upstream

## Offline VCP patch

`patch-usb-port-select.rb` adds Set-VCP code `EA` without changing the image
size or any existing advertised VCP command. `EA` is unadvertised and its
original Set-VCP table target is a one-byte `RET` at `EF40`.

The patch makes only two changes in bank 2:

- redirects the Set-VCP `EA` table entry at `E3A6` from `EF40` to `FF00`;
- places a 31-byte handler in the erased `FF00` code cave.

The script accepts only the exact 1,179,648-byte V007 image with SHA-256:

`7230e10cd846f99dd20ab0f8a3a29f0e50fcf551ce480f4adbed18d9a941ba35`

Usage:

```sh
./patch-usb-port-select.rb ORIGINAL.bin PATCHED.bin
```

Set-VCP `EA=0` selects the USB-C upstream. Set-VCP `EA=1` selects USB-B.
Video input remains VCP `60`, so the final utility can issue both commands as
one KVM action.

## Safety status

The patch is statically verified; it has not yet been flashed to physical
hardware. The new handler was also imported independently and decompiled to
confirm that it performs only the intended hub selection and update call.

The official updater's managed code was inspected as well. It:

- splits the image into 18 64-KiB banks;
- erases and writes banks in reverse order, in 256-byte pages up to each
  bank's last non-`FF` byte;
- runs the scaler's hardware CRC over the bytes it wrote, but does not compare
  the result with an embedded checksum or signature.

The patch extends bank 2's used range from `FEFE` to `FF1E`; the updater's page
loop includes that final page. No image checksum field needs recalculation.
This removes the known format/integrity obstacle, but it does not remove the
ordinary risk of a power or USB interruption during erase/write.

The exact original image and official Windows updater dependencies are kept in
[`recovery`](recovery/README.md). Flashing remains a separate, explicit step;
nothing in this directory enters ISP mode or writes the monitor by itself.
