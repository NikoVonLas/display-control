# XV282K KV V007 recovery bundle

This bundle preserves the exact original firmware and the vendor's Windows
updater files before any physical flash attempt.

## SHA-256

```text
7230e10cd846f99dd20ab0f8a3a29f0e50fcf551ce480f4adbed18d9a941ba35  original-firmware/Acer_XV282K_KV_2HDPTC_RTD2718QD_INX_M280DCA-E7B_20210729_V007_F709_Reduce.bin
0093a5cecdd54993c7cf6acc207dd9183e394371468b00712c7c5fcf167458c8  windows-updater/Monitor_USB_Upgrade_Tool_XV282KKV.exe
44ec5842b9a873bc80f60b0c474b4fd1a5e2786c9f4065b4a72bc562a7e02dbb  windows-updater/Rtshublib.dll
4498d8d1a0549717852507993b7c0350d1da408d22943ed8244d16441abfaf99  windows-updater/WpfAnimatedGif.dll
```

The patched image is one directory above, under `build`, with SHA-256:

```text
646661738fa9b2c8d6dd5850140a9d8c32270675d21e3b18d7a8af7a252b7219  Acer_XV282K_KV_V007_USB_HUB_VCP_EA.bin
```

Run `shasum -a 256 -c SHA256SUMS` from this directory to verify the complete
bundle and patched image.

## Before a controlled flash

- Use a Windows machine connected directly to the monitor by USB Type-B or
  USB-C; do not put a dock or hub in between.
- In the monitor OSD, set `USB Port Select` to the same cable type used by the
  updater.
- Keep the computer on AC power, prevent sleep, and use stable monitor power.
- Keep the original and patched `.bin` files clearly separated and verify the
  SHA-256 of the file selected in the updater.
- Do not disconnect USB or power while erase/write is in progress. The vendor
  guide says the update takes about eight minutes and requires a monitor power
  unplug/replug after success.

The vendor guide's response to an update error is to close the updater, power
cycle the monitor, and retry. That is not proof of recovery after every possible
interrupted erase, so a physical flash should be treated as a controlled risk,
not as a guaranteed reversible operation.
