# Acer XV282K KV V11 — complete VCP inventory

Snapshot date: 2026-09-04. Firmware: patched V11 based on Acer V007.
Current video connection reported by Windows as external DisplayPort
(`VideoOutputTechnology = 10`).

## Scope and warnings

- The V11 firmware tables contain **59 distinct VCP codes**.
- **57** have a Get-table entry; **46** have a Set-table entry.
- **54 of 57** Get entries returned a value on the current digital input.
- `20`, `30`, and `7E` have firmware Get entries but failed at runtime. They are
  legacy geometry controls and are not useful on this digital panel/input.
- Set entries for `06`, `0E`, `20`, and `30` point to a plain return stub; treat
  them as nonfunctional writes.
- The monitor's capability string advertises only **30** VCP codes. Extra firmware
  entries are real implementation details but not a promise that writing them is
  safe in every picture/input mode.
- `E0..FF` are manufacturer-specific under MCCS. Do not write unknown vendor codes
  merely because Get succeeds. `EA` is the only added and fully documented code.

Access legend: `R/W` = Get and Set table entries, `R` = Get only, `W` = Set only,
`stub` = recognized but the Set handler does nothing. Current and maximum are the
raw values returned by Windows DXVA2.

## Complete union of V11 Set/Get tables

| VCP | MCCS / identified function | Access | Runtime Get: current / max | Notes |
|---:|---|:---:|:---:|---|
| `02` | New Control Value | R/W | `1 / 2` | MCCS synchronization flag |
| `04` | Restore Factory Defaults | R/W | `0 / 1` | Momentary; destructive to settings |
| `05` | Restore Factory Luminance/Contrast Defaults | R/W | `0 / 1` | Momentary reset |
| `06` | Restore Factory Geometry Defaults | R/stub | `0 / 1` | Set handler is RET |
| `08` | Restore Factory Color Defaults | R/W | `0 / 1` | Momentary reset |
| `0B` | Color Temperature Increment | R | `100 / 0` | Read-only here |
| `0C` | Color Temperature Request | R/W | `35 / 63` | Standard MCCS color temperature control |
| `0E` | Clock | stub | n/a | Set-table entry is RET; no Get entry |
| `10` | Luminance / Brightness | R/W | `70 / 100` | Advertised |
| `12` | Contrast | R/W | `50 / 100` | Advertised |
| `14` | Select Color Preset | R/W | `5 / 11` | Advertised values: `05 06 08 0B` |
| `16` | Video Gain: Red | R/W | `50 / 100` | Advertised |
| `18` | Video Gain: Green | R/W | `50 / 100` | Advertised |
| `1A` | Video Gain: Blue | R/W | `50 / 100` | Advertised |
| `1E` | Auto Setup | R | `0 / 1` | Legacy analog function |
| `20` | Horizontal Position | R/stub | **failed** | Digital mode; Set is RET |
| `30` | Vertical Position | R/stub | **failed** | Digital mode; Set is RET |
| `52` | Active Control | R/W | `0 / 1` | Not advertised |
| `59` | 6-axis Saturation: Red | R/W | `50 / 100` | Advertised |
| `5A` | 6-axis Saturation: Yellow | R/W | `50 / 100` | Advertised |
| `5B` | 6-axis Saturation: Green | R/W | `50 / 100` | Advertised |
| `5C` | 6-axis Saturation: Cyan | R/W | `50 / 100` | Advertised |
| `5D` | 6-axis Saturation: Blue | R/W | `50 / 100` | Advertised |
| `5E` | 6-axis Saturation: Magenta | R/W | `50 / 100` | Advertised |
| `60` | Input Select | R/W | `15 / 3` | `0F` DP, `11` HDMI-1, `12` HDMI-2 |
| `62` | Speaker Volume | R/W | `62 / 100` | Advertised |
| `6C` | Video Black Level: Red | R/W | `50 / 100` | Not advertised |
| `6E` | Video Black Level: Green | R/W | `50 / 100` | Not advertised |
| `70` | Video Black Level: Blue | R/W | `50 / 100` | Not advertised |
| `7E` | Legacy Trapezoid/geometry control | R | **failed** | Firmware entry, unusable here |
| `87` | Sharpness | R/W | `2 / 4` | Not advertised |
| `9B` | 6-axis Hue/Color: Red | R/W | `50 / 100` | Advertised |
| `9C` | 6-axis Hue/Color: Yellow | R/W | `50 / 100` | Advertised |
| `9D` | 6-axis Hue/Color: Green | R/W | `50 / 100` | Advertised |
| `9E` | 6-axis Hue/Color: Cyan | R/W | `50 / 100` | Advertised |
| `9F` | 6-axis Hue/Color: Blue | R/W | `50 / 100` | Advertised |
| `A0` | 6-axis Hue/Color: Magenta | R/W | `50 / 100` | Advertised |
| `AC` | Horizontal Frequency | R | `5 / 2220` | Read-only timing data; raw encoding |
| `AE` | Vertical Frequency | R | `14420 / 65535` | Read-only; `14420` corresponds to 144.20 Hz |
| `B2` | Flat-panel Sub-pixel Layout | R | `1 / 1` | Read-only identification |
| `B6` | Display Technology Type | R | `3 / 5` | Read-only identification |
| `C6` | Application Enable Key | R | `90 / 255` | Read-only here |
| `C8` | Display Controller ID | R | `9 / 0` | Read-only identification |
| `C9` | Display Firmware Level | R | `1 / 65535` | Raw firmware encoding |
| `CA` | OSD Control | R/W | `1 / 2` | Not advertised; use cautiously |
| `CC` | OSD Language | R/W | `9 / 13` | Not advertised |
| `D6` | Power Mode | R/W | `1 / 5` | Advertised; can power down display |
| `DF` | VCP Version | R | `514 / 65535` | `514 = 0x0202`, MCCS 2.2 |
| `E0` | Acer/Realtek manufacturer-specific | R/W | `255 / 10` | Advertised values `00 04 05 07 09 0A`; `FF` currently inactive/sentinel |
| `E1` | Acer/Realtek manufacturer-specific | R/W | `255 / 10` | Advertised values `00 01 02`; `FF` currently inactive/sentinel |
| `E2` | Acer Color Mode / game preset control | R/W | `17 / 27` | Capability string names User, Standard, Eco, Graphics, game modes, sRGB, HDR, save slots |
| `E3` | Acer/Realtek manufacturer-specific | R | `452 / 4095` | Read-only firmware entry |
| `E4` | Acer/Realtek manufacturer-specific | R | `1 / 3` | Read-only firmware entry |
| `E5` | Acer/Realtek manufacturer-specific | R/W | `5 / 10` | Advertised, semantics not proven |
| `E7` | Acer/Realtek manufacturer-specific | R/W | `255 / 3` | Advertised values `00 01 02`; `FF` currently inactive/sentinel |
| `E8` | Acer/Realtek manufacturer-specific | R/W | `255 / 3` | Advertised values `00..04`; runtime max differs from advertised list |
| `E9` | Acer/Realtek manufacturer-specific | R/W | `255 / 6` | Hidden stock handler; semantics not proven |
| `EA` | **USB Port Select — V11 custom API** | R/W | `0 / 1` | `0` B-Type, `1` C-Type; live-tested both directions |
| `FC` | Acer/Realtek manufacturer-specific | W | n/a | Set-only; semantics unknown; do not probe |

## Capability string advertised VCP set

The stock capability string advertises:

`04 10 12 14 16 18 1A 59 5A 5B 5C 5D 5E 60 62 9B 9C 9D 9E 9F A0 D6 E0 E1 E2 E3 E4 E5 E7 E8`

Input Select values advertised by the monitor:

- `0F` — DisplayPort
- `11` — HDMI 1
- `12` — HDMI 2

V11 deliberately does not rewrite the capability string, so custom code `EA` is
absent from it even though Get/Set EA are implemented and live-tested.

## Transport behavior

VCP traffic is carried by the video connection's DDC/CI channel, not by the USB-B or
USB-C data upstream selected by VCP EA.

- **HDMI:** expected to work through HDMI DDC when the controlling PC has an active
  HDMI connection to the monitor and DDC/CI is enabled. This V11 build uses the same
  common VCP dispatcher for all inputs. HDMI has not yet been physically retested.
- **DisplayPort:** confirmed on the current Windows connection, reported as external
  DisplayPort (`10`).
- **USB-C DisplayPort Alt Mode:** expected to work because the GPU/driver transports
  DDC/CI over DisplayPort AUX. Windows may report both native DP and USB-C DP Alt Mode
  simply as external DisplayPort, so the present WMI result cannot distinguish them.
  Some docks and KVMs may block DDC/CI even though the monitor firmware supports it.
- There is no “DVI Alt Mode.” If DVI was meant literally, DDC/CI can exist over DVI,
  but this monitor has no DVI input. The relevant USB-C video mode is DP Alt Mode.

## Read-only rescan

Run `Get-AllV11Vcp.ps1`. It sends Get VCP only and does not change any monitor value.
