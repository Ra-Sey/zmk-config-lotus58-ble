# Lotus58 BLE: Keymap, Matrix Fixes, Encoder and Display Integration

This document covers three things: the charlieplex matrix defects found and
fixed after the initial bring-up (see `docs/bringup-and-debugging.md` for the
earlier BLE/bootloader/clock defects), the current keymap as shipped, and the
work done to add the right-half rotary encoder and nice!view display. It also
documents how to move the split central ("master") role from the left half to
the right half, and answers on display content/configuration and keymap
editing tools.

Scope: `zmk-config-lotus58-ble` only. Hardware evidence throughout was pulled
directly from `Hardware/Lotus-58-BLE/v1.20/Lotus58_BLE.kicad_sch` (paths in
this document are relative to the `Keyboard_Split` project root unless noted
as repo-relative to `zmk-config-lotus58-ble`).

---

## 1. Charlieplex matrix defects

Reported symptom: a reproducible set of dead keys, identical between two
independently hand-soldered boards (see `Debugging.md` for the original
measurement tables). One genuinely missing diode was found and fixed by hand;
the remaining dead keys persisted after that repair, which is what triggered
this investigation.

### 1.1 `rows = <5>` instead of `<6>`

`boards/tweetydabird/lotus58_ble/lotus58_ble.dtsi`, `keymap_transform_0`.

The charlieplex kscan driver reports `RC(a,b)`, where both `a` and `b` are
indices into the same six GPIOs (`Pin0`..`Pin5`) — `a` is the pin the
switch's individual diode connects to, `b` is the pin the switch shares with
the rest of its schematic row. Both indices therefore run `0..5`, but the
matrix transform declared `rows = <5>`. Every switch whose diode lands on
`Pin5` reports row index 5, which is out of range for a 5-row transform, so
the position is silently dropped.

Fix: `rows = <6>`.

### 1.2 The `map` did not match the real wiring

The old `map` was a generic sequential `RC(row,col)` assignment with no
relationship to the actual charlieplex wiring. It happened to produce a valid
build (no dead positions from this alone), but every key sent the wrong
character.

Fix: extracted the true net list from `Lotus58_BLE.kicad_sch` directly
(wire/junction/label graph, union-find over segment endpoints, pin positions
resolved from each symbol's placement and rotation) instead of trusting the
schematic's schematic-only pin-map comment block. Result, shared-pin →
switches → individual diode pin:

| Shared pin | Switches | Diode pins (in switch order) |
|---|---|---|
| Pin1 | SW01–SW05 | Pin2, Pin3, Pin4, Pin5, Pin0 |
| Pin2 | SW06–SW10 | Pin1, Pin3, Pin4, Pin5, Pin0 |
| Pin3 | SW11–SW15 | Pin1, Pin2, Pin4, Pin5, Pin0 |
| Pin4 | SW16–SW20 | Pin1, Pin2, Pin3, Pin5, Pin0 |
| Pin5 | SW21–SW25 | Pin1, Pin2, Pin3, Pin4, Pin0 |
| Pin0 | SW26–SW29 | Pin2, Pin3, Pin4, Pin5 |

The `map` in the `.dtsi` was rebuilt from this table combined with the
physical key ordering already documented in the surrounding comments.

### 1.3 Keymap had 60 bindings per layer instead of 58

`boards/tweetydabird/lotus58_ble/lotus58_ble.keymap`, all three layers. Row 3
had two extra entries (`&kp BSLH`, `&kp LS(MINUS)`) that belong to row 4 only
(the inner thumb-adjacent key exists once per half in row 4, not row 3). ZMK
silently uses the first 58 entries of an oversized `bindings` list, so
everything from position 30 onward was shifted two slots to the left of where
it should have been. Fixed by removing the two extra entries from row 3 in
every layer.

### 1.4 Verification

All three fixes were checked together against every one of the 29 measured
key results recorded for board 2 in `Debugging.md`: for each switch, the
expected `RC()` value was computed from the extracted wiring table above,
looked up in the corrected `map`, resolved to a keycode, and translated to
the character a German host layout would produce. Result: **29/29 matches,
0 mismatches** — every working key produced exactly the measured character,
and every dead key was dead for exactly the reason the fix addresses. This
confirms the remaining failures were 100% a software defect, not additional
cold solder joints.

---

## 2. Current keymap

Physical layout: 58 keys, `columns = <12>`, `rows = <6>` (after the fix
above), right half shifted by `col-offset = <6>`.

```
Row 1: SW01 SW02 SW03 SW04 SW05 SW06  |  SW06 SW05 SW04 SW03 SW02 SW01
Row 2: SW07 SW08 SW09 SW10 SW11 SW12  |  SW12 SW11 SW10 SW09 SW08 SW07
Row 3: SW13 SW14 SW15 SW16 SW17 SW18  |  SW18 SW17 SW16 SW15 SW14 SW13
Row 4: SW19 SW20 SW21 SW22 SW23 SW24 SW29  |  SW29 SW24 SW23 SW22 SW21 SW20 SW19
Thumb:           SW25 SW26 SW27 SW28  |  SW28 SW27 SW26 SW25
```

### 2.1 Layers

`boards/tweetydabird/lotus58_ble/lotus58_ble.keymap` defines three layers:

- **`default_layer`** (`display-name = "UNIQUE"`) — every physical position
  sends a distinct keycode (`GRAVE`, `N1`..`N0`, `Q`..`P`, etc., including
  shifted punctuation on the thumb keys). This is a **diagnostic layout**,
  not an everyday one: its purpose is that pressing any single key uniquely
  identifies which physical position it is, which is exactly what made the
  matrix-fix verification in Section 1.4 possible. It is not a QWERTY/QWERTZ
  typing layout.
- **`lower_layer`** / **`raise_layer`** — both entirely `&trans` (transparent)
  right now. They exist as placeholders but are **not reachable**: no key in
  `default_layer` is bound to `&mo 1`, `&mo 2`, `&lt`, or similar. Until a
  key is bound to switch layers, these two layers can never activate.

### 2.2 Encoder binding

Each layer has one `sensor-bindings` entry (one per sensor declared in
`&sensors`, see Section 3):

```dts
sensor-bindings = <&inc_dec_kp A B>;
```

This is a placeholder — clockwise sends `A`, counter-clockwise sends `B`. A
more typical binding would be e.g. `&inc_dec_kp C_VOL_UP C_VOL_DN` for volume.

---

## 3. Adding the right-half rotary encoder

### 3.1 Hardware evidence

The MCU-pin extraction was done the same way as the matrix net list (Section
1.2), reading pin-to-net connections directly off the `E73-2G4M08S1C_test`
symbol instances in the schematic. Both halves (`U7`, `U2`) wire the encoder
footprint identically:

| Net | MCU pin |
|---|---|
| `EncA` | P1.11 |
| `EncB` | P1.13 |

The footprint exists on both PCBs; only the right half is actually populated.

### 3.2 Latent bug in the existing scaffold

A commented-out encoder block already existed in `lotus58_ble.dtsi`, left
over from an earlier template. It used `&gpio1 10` for `a-gpios` — but the
schematic says `P1.11`, not `P1.10`. Simply uncommenting it would have
produced a build that compiled fine but read the wrong GPIO for encoder
channel A. Fixed to `&gpio1 11`.

### 3.3 Single-sensor simplification

The original scaffold declared two encoders (`left_encoder` **and**
`right_encoder`, both wired to the same pins, referenced together in one
`sensors` node) — a pattern intended for boards where either half might carry
an independent encoder. Since this board only ever has one physical encoder
(right half only, by design), that dual-slot scaffold was replaced with a
single sensor, matching the pattern ZMK's own documentation prescribes for
this exact case (`docs/hardware-integration/encoders.md` upstream): one
`encoder_right` node, disabled by default, one `sensors` node listing just
that node, enabled via a `status = "okay"` override in the board file that
actually has the hardware.

### 3.4 Files changed

| File | Change |
|---|---|
| `boards/tweetydabird/lotus58_ble/lotus58_ble.dtsi` | `right_encoder` node (correct GPIO pins, `status = "disabled"`), `sensors` node referencing only `&right_encoder` |
| `boards/tweetydabird/lotus58_ble/lotus58_ble_right.dts` | `&right_encoder { status = "okay"; };` |
| `boards/tweetydabird/lotus58_ble/lotus58_ble_right.conf` (new) | `CONFIG_EC11=y`, `CONFIG_EC11_TRIGGER_GLOBAL_THREAD=y` — right-only, since the left half has no encoder hardware to drive |
| `boards/tweetydabird/lotus58_ble/lotus58_ble.keymap` | `sensor-bindings` reduced from two entries to one per layer, matching the single sensor |
| `boards/tweetydabird/lotus58_ble/lotus58_ble.zmk.yml` | added `encoder` to `features:` |

---

## 4. Adding the nice!view display

### 4.1 Hardware evidence

Same schematic extraction, both halves identical:

| Net | MCU pin |
|---|---|
| `SCK` | P0.29 |
| `MOSI` | P0.30 |
| `CS` | P0.31 |

These already matched a commented-out `nice_view_spi: &spi1 { ... };` block in
the `.dtsi`, including the `cs-gpios` value — that part of the scaffold was
correct, just inactive.

### 4.2 Design choice: official `nice_view` shield, not a custom driver

The pre-existing scaffold named the SPI bus label exactly `nice_view_spi`,
which is the label ZMK's own `nice_view` shield overlay expects
(`&nice_view_spi { status = "okay"; nice_view: ls0xx@0 { compatible =
"sharp,ls0xx"; ... }; };`, confirmed against ZMK's upstream source). That
naming was almost certainly intentional in the original template, so rather
than writing a custom display driver and status-screen widget, the board now
applies the official `nice_view` shield to the right build only. The shield
brings its own display node, `CONFIG_ZMK_DISPLAY`, and LVGL Kconfig
defaults — none of that needed to be hand-written.

### 4.3 Files changed

| File | Change |
|---|---|
| `boards/tweetydabird/lotus58_ble/lotus58_ble.dtsi` | `nice_view_spi` (`&spi1`) uncommented: `compatible`, pinctrl, `cs-gpios`. No forced `status = "okay"` — left inherits the SoC default (disabled); the shield enables it only where applied |
| `build.yaml` | `shield: nice_view` added to the `lotus58_ble_right` build entry only |
| `boards/tweetydabird/lotus58_ble/Kconfig.defconfig` | removed the obsolete commented-out `ZMK_DISPLAY`/LVGL block — the shield's own `Kconfig.defconfig`, scoped to `SHIELD_NICE_VIEW`, covers this |
| `boards/tweetydabird/lotus58_ble/lotus58_ble.conf` | removed the now-obsolete "uncomment to enable display" comment |
| `boards/tweetydabird/lotus58_ble/lotus58_ble.zmk.yml` | added `display` to `features:` |

### 4.4 Conf-file merge convention (why a bare `lotus58_ble.conf` still matters)

Zephyr's Hardware Model V2 board layout merges **both** a board-family
`.conf` file and a board-target-specific one for a given build (confirmed
against ZMK's own `corneish_zen.conf` + `corneish_zen_right_..._defconfig`,
and `kyria.conf` + `kyria_right.conf` in the upstream ZMK tree). That's why
`lotus58_ble_right.conf` (Section 3.4) is picked up automatically alongside
the shared `lotus58_ble.conf` for the `lotus58_ble_right` build, with no
extra wiring needed.

---

## 5. What the display currently shows

The split central ("master") role is fixed to the **left** half
(`config ZMK_SPLIT_ROLE_CENTRAL default y` under `if BOARD_LOTUS58_BLE_LEFT`
in `Kconfig.defconfig`), but the display sits on the **right**, peripheral
half. The `nice_view` shield's `CMakeLists.txt` compiles different widget
code depending on that role:

- central → `widgets/status.c` (battery, BLE/USB output status, active
  layer, WPM)
- peripheral → `widgets/art.c` + `widgets/peripheral_status.c`

Since the right half builds as a peripheral, the display currently shows:

- top right: right half's own battery level, plus a symbol for whether the
  BLE link to the left half is up (Wi-Fi-style icon) or down (X) — this is
  the internal split link, not the connection to the host PC
- left side: a random decorative image (balloon or mountain, re-rolled every
  boot)

It does **not** show the active layer, host output status, WPM, or the left
half's battery — those only exist in the central-side widget, and the
central side has no display.

---

## 6. Making the right half the central ("master") half

Not applied — this is a documented procedure, not a change made to the repo.
Doing this would also fix Section 5: once the right half is central, its
already-installed display automatically gets the full `widgets/status.c`
screen (layer, output, WPM, battery) instead of the reduced peripheral
widget, purely because the shield's `CMakeLists.txt` branches on the same
`ZMK_SPLIT_ROLE_CENTRAL` Kconfig symbol — no devicetree change needed.

Steps, all in `boards/tweetydabird/lotus58_ble/Kconfig.defconfig`:

1. Move `config ZMK_SPLIT_ROLE_CENTRAL` / `default y` out of the
   `if BOARD_LOTUS58_BLE_LEFT` block and into the `if BOARD_LOTUS58_BLE_RIGHT`
   block.
2. Move (or duplicate) `config ZMK_KEYBOARD_NAME` / `default "Lotus58 BLE"`
   the same way — only the central half's `ZMK_KEYBOARD_NAME` is used for BLE
   advertising, so if it stays under the left block, the keyboard would
   advertise under the wrong/no name after the swap.
3. Rebuild both halves and reflash both — the role is baked in at compile
   time, it cannot be changed at runtime.
4. Re-pair: since central is the half that talks to the host, pairing has to
   be (re-)done from the right half after the swap; the host will see it as
   a new/different device from before.

No `.dtsi`/`.dts`/`.keymap` changes are required for this swap — it is purely
a `Kconfig.defconfig` edit.

---

## 7. Configuring the display, layers, and keymap-editing tools

### 7.1 Display content

Simple options are plain Kconfig, e.g. `CONFIG_NICE_VIEW_WIDGET_INVERTED=y`
(inverted colors) in `lotus58_ble_right.conf`. Changing what is actually
drawn (replacing the balloon/mountain art, adding a layer indicator to the
peripheral widget, etc.) is not a config value — it means copying the
`nice_view` shield's `widgets/*.c` files into a local shield and editing the
LVGL drawing code directly.

### 7.2 Layers

Edited directly in `lotus58_ble.keymap`. As noted in Section 2.1, `lower_layer`
and `raise_layer` currently have no key bound to reach them — a `&mo 1`/`&mo 2`
(or `&lt`) binding needs to be added to `default_layer` before they do
anything.

### 7.3 Web tools for keymap editing

Two options, very different setup cost:

- **ZMK Keymap Editor** (`nickcoutsos.github.io/keymap-editor`) — no firmware
  changes needed. Sign in with GitHub, grant it access to this repo, edit the
  `.keymap` graphically; it commits back to the repo and the existing GitHub
  Actions workflow builds new firmware to flash. This is the "just works"
  option.
- **ZMK Studio** (`zmk.studio`) — live keymap editing on the device, no
  reflashing. Setup cost is real, not just a checkbox:
  1. `snippet: studio-rpc-usb-uart` and `-DCONFIG_ZMK_STUDIO=y` added to the
     **central** half's `build.yaml` entry only.
  2. A `&studio_unlock` binding added somewhere in the keymap.
  3. The physical layout must be defined with a `keys` property (per-key x/y
     coordinates), and the board must **not** use a `chosen`
     `zmk,matrix-transform` — this board currently uses the
     transform-based layout (Section 1), not the coordinate-based one Studio
     requires. Building that `keys` property is a separate task (derivable
     from key placement in `Hardware/Lotus-58-BLE/v1.20/Lotus58_BLE.kicad_pcb`,
     the same way the matrix net list was extracted in Section 1.2), not
     something enabled by a flag.

  Recommendation: start with the Keymap Editor; only invest in Studio's
  physical-layout work if live, no-reflash editing is worth it.
