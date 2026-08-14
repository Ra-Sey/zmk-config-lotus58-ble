# Lotus58 BLE: ZMK Bring-Up and Debugging Log

This document is the complete record of bringing ZMK firmware up on the
Lotus58 BLE (v1.20, TweetyDaBird, Ebyte E73-2G4M08S1C / nRF52840). It covers
every defect found between the initial ZMK Hardware Model V2 migration and
the point where the left half enumerated as a USB HID keyboard and
advertised over BLE, in the order the defects were found and fixed. Each
section states the symptom, the root cause with supporting evidence, the
fix, and the exact commands used to reproduce the diagnosis.

Scope: this repository (`zmk-config-lotus58-ble`) plus the separate
`Adafruit_nRF52_Bootloader` checkout at
`Software/Adafruit_nRF52_Bootloader/` (its own board-specific patches and
build/flash instructions are in
`Software/Adafruit_nRF52_Bootloader/BootloaderHackTutorial.md`; this
document assumes that one has already been read for the bootloader side).

Related commits in this repository:

| Commit | Date | Summary |
|---|---|---|
| `8574375` | 2026-08-13 | Migrate to ZMK Hardware Model V2; fix split BLE central-role bug |
| `82e95eb` | 2026-08-14 | Partition table fix (SoftDevice-less bootloader) |
| `fdf2283` | 2026-08-14 | Use internal RC oscillator for the 32.768 kHz clock |

---

## 1. Hardware summary

- MCU: Nordic nRF52840 (QIAA), inside an Ebyte E73-2G4M08S1C module.
- Reference: `Hardware/Datasheets/Controller/E73-2G4M08S1C_UserManual_EN_v2.4.pdf`.
- Schematic: `Hardware/Lotus-58-BLE/v1.20/Lotus58_BLE.kicad_sch`.
- Charger: TI BQ24075 (U1), feeding `+BATT`.
- 32.768 kHz crystal Y1 (XC32M4-32.768-F12NJDTL) on module pins 11/13
  (XL1/XL2 = P0.00/P0.01), with 12 pF load capacitors C9/C10. Populated, but
  see Section 5 -- it does not oscillate on this board revision.
- No SoftDevice: ZMK is built directly against Zephyr's Bluetooth
  controller/host, so the target flash layout has no `sd_partition` and the
  bootloader is built without a Nordic SoftDevice image.
- Two assembled LEDs: LED1 (orange, hardwired to the charger's `CHG` output,
  not GPIO-controlled) and LED2 (blue, `ZMK_LED` net, intended on P1.10).
  LED2's actual PCB wiring is reversed -- see Section 5.4.

---

## 2. Timeline overview

| # | Symptom | Root cause | Fix location |
|---|---|---|---|
| 1 | Right half acted as a second BLE central | `CONFIG_BOARD_LOTUS58_BLE_LEFT=y` left set in the right board's defconfig | `zmk-config-lotus58-ble` (pre-existing HWMv2 migration, `8574375`) |
| 2 | Flashing appeared to succeed, board came back as a USB drive instead of booting | ZMK application still linked at `0x27000` (nice!nano/SoftDevice layout); bootloader has no SoftDevice and looks for the app at `0x1000` | `zmk-config-lotus58-ble`, partition table (`82e95eb`) |
| 3 | After the partition fix, the board still never left DFU mode, no HID, no BLE, no LED | Bootloader's `BUTTON_1` (used as `BUTTON_DFU`) was wired to P0.18, the same pin as the physical RESET button; it forced DFU entry on every boot | `Adafruit_nRF52_Bootloader`, `src/boards/pca10056/board.h` |
| 4 | After the button fix, the bootloader worked but the app enumerated nothing at all: no HID, no BLE, no LED | Application requested the 32.768 kHz crystal (`K32SRC_XTAL`, Zephyr default); the crystal does not oscillate on this board, so `bt_enable()` blocked forever in a SYS_INIT and USB was never brought up either | `zmk-config-lotus58-ble`, board defconfigs (`fdf2283`) |
| 5 | (Informational, not fixed in firmware) LED2 never lights regardless of firmware | PCB wiring has LED2's anode tied to GND through R6 and its cathode to the GPIO -- reversed polarity, cannot conduct in either GPIO state | Hardware defect, PCB rework needed |

Items 3 and 4 were only found because item 2's fix, although correct, was
not sufficient by itself -- each defect fully masked the next one until the
one before it was removed. Section 6 explains why static review missed
items 3 and 4 and what made them observable.

---

## 3. ZMK Hardware Model V2 migration and the split-role bug

(Carried forward from the prior migration pass; summarized here for
continuity. Full original write-up: commit `8574375`.)

### 3.1 Split BLE central-role bug

`config/boards/arm/lotus58_ble/lotus58_ble_right_defconfig` (old,
pre-migration path) set `CONFIG_BOARD_LOTUS58_BLE_LEFT=y` in addition to the
automatically-selected `CONFIG_BOARD_LOTUS58_BLE_RIGHT=y`. Because
`Kconfig.defconfig` sets `CONFIG_ZMK_SPLIT_ROLE_CENTRAL=y` only inside
`if BOARD_LOTUS58_BLE_LEFT`, the right half's build ended up centralized as
well. Two simultaneous BLE centrals cannot form a split link, and the right
half additionally tried to advertise as a standalone central to hosts.

Fixed as part of the HWMv2 migration: the new
`boards/tweetydabird/lotus58_ble/Kconfig.lotus58_ble_right` sets no
`BOARD_*` symbol manually at all; HWMv2's board.yml-driven selection handles
it.

### 3.2 Migration to Hardware Model V2 (Zephyr 4.1)

ZMK's `main` branch moved to Zephyr 4.1 in December 2025, introducing
Hardware Model V2 (HWMv2) for out-of-tree boards. Applied by hand (ZMK's
automatic upgrade script explicitly does not support split keyboards),
mirroring ZMK's in-tree split boards (e.g. MoErgo Glove80):

| Old (HWMv1) | New (HWMv2) |
|---|---|
| `config/boards/arm/lotus58_ble/` | `boards/tweetydabird/lotus58_ble/` |
| `Kconfig.board` with `bool` + `depends on SOC_...` | `Kconfig.lotus58_ble_left` / `Kconfig.lotus58_ble_right`, each `select`-ing the SoC and `ZMK_BOARD_COMPAT` |
| `<board>_defconfig` selecting `CONFIG_SOC_*` / `CONFIG_BOARD_*` | Those selects removed; HWMv2 derives them from `board.yml` |
| No `board.yml` | `board.yml` declaring both left/right boards, SoC `nrf52840` |

`board.yml` declares no `variants:`, so the build target is the plain board
name (`lotus58_ble_left` / `lotus58_ble_right`), no `/zmk` suffix. The
devicetree, pinctrl, keymap, and Kconfig content did not need to change --
the charlieplex kscan driver, the `zmk,battery-nrf-vddh` driver, and the
matrix-transform/physical-layout bindings are unchanged in current ZMK.

The board files must live at the repository root under `boards/` (not
`config/boards/`) for `zephyr/module.yml`'s `board_root: .` to find them;
`config/boards` is a deprecated legacy fallback path. A first CI run after
this move failed with "No board named 'lotus58_ble_left' found" because
`zephyr/module.yml` itself had never been committed -- `.gitignore` had a
blanket `zephyr/` rule intended to keep the real Zephyr RTOS checkout
(created locally by `west update`) out of git, which also silently excluded
the hand-written `zephyr/module.yml`. Fixed by scoping the ignore rule to
`zephyr/*` while explicitly keeping `zephyr/module.yml` tracked. Diagnostic:
`git ls-files zephyr` should list `module.yml`.

### 3.3 `west.yml`: tracking `main`

Changed `revision: v0.3` to `revision: main` to get HWMv2/Zephyr-4.1 support,
matched by both GitHub Actions workflows
(`zmkfirmware/zmk/.github/workflows/build-user-config.yml@main`). Trade-off:
`main` is ZMK's "tester" channel and can have breaking changes; re-pin to a
release tag once ZMK ships a Zephyr-4.1-based release.

### 3.4 Metadata typo

`lotus58_ble.zmk.yml` / `lotus58_ble.yaml`: `sibllings:` corrected to
`siblings:` (schema did not recognize the misspelled key, so the left/right
sibling relationship was silently not recorded). Also removed `display`,
`encoder`, `underglow`, `backlight` from the declared `features:` list --
none of these are wired up in the devicetree/Kconfig (nice!view SPI pins and
the encoder nodes are present but commented out as unverified).

---

## 4. SoftDevice-less bootloader migration: partition table

### 4.1 Symptom

Flashing the ZMK application UF2 appeared to succeed (the drive accepted the
copy), but the board came back as a USB mass-storage drive instead of
booting -- it never enumerated as a HID keyboard.

### 4.2 Root cause

The bootloader determines the application's start address by asking the
SoftDevice for its size. With no SoftDevice present, that answer is "none",
so the bootloader looks for the application immediately after the MBR, at
`0x1000`. The ZMK board's devicetree still used the nice!nano/SoftDevice
partition layout, with the application linked at `0x27000`. The bootloader
found erased flash at `0x1000`, concluded no application existed, and
re-entered DFU mode every time.

### 4.3 Fix

`boards/tweetydabird/lotus58_ble/lotus58_ble.dtsi`, `&flash0` partition
table, changed from the nice!nano-style layout (`sd_partition` at
`0x0`-`0x27000`, `code_partition` at `0x27000`) to:

```dts
&flash0 {
  partitions {
    compatible = "fixed-partitions";
    #address-cells = <1>;
    #size-cells = <1>;

    mbr_partition: partition@0 {
      label = "mbr";
      reg = <0x00000000 0x00001000>;
    };

    code_partition: partition@1000 {
      label = "code_partition";
      reg = <0x00001000 0x000eb000>;
    };

    storage_partition: partition@ec000 {
      label = "storage";
      reg = <0x000ec000 0x00008000>;
    };

    boot_partition: partition@f4000 {
      label = "adafruit_boot";
      reg = <0x000f4000 0x0000c000>;
    };
  };
};
```

`CONFIG_USE_DT_CODE_PARTITION=y` was already present in both
`lotus58_ble_left_defconfig` and `lotus58_ble_right_defconfig` -- without it,
Zephyr links the image at the flash base and silently ignores
`code_partition`, which is the most common way this class of bug hides even
after the devicetree looks correct. Nothing else in the repository
referenced the old `0x27000` address (`grep -rn "0x27000\|sd_partition"`
across the tree came back empty after the change).

### 4.4 Verification

Reading the currently-flashed image back from the bootloader's DFU drive and
checking where its data actually starts is the authoritative check --
it reads back what is physically in flash, independent of what was intended
to be built or flashed:

```bash
# with the board in DFU mode (double-tap reset), the bootloader exposes
# CURRENT.UF2 on its mass-storage drive:
python3 check_uf2.py /media/<user>/LOTUSBLE/CURRENT.UF2
```

`check_uf2.py` (UF2 block format: 512-byte blocks, magic
`0x0A324655`/`0x9E5D5157`, target address at offset 12, payload at offset
32, initial SP/reset vector at offset 32/36 of the first non-empty block):

```python
import struct, sys

d = open(sys.argv[1], 'rb').read()
runs, cur = [], None

for i in range(0, len(d), 512):
    b = d[i:i+512]
    magic0, magic1 = struct.unpack('<II', b[0:8])
    assert magic0 == 0x0A324655 and magic1 == 0x9E5D5157, "not a UF2 file"
    addr = struct.unpack('<I', b[12:16])[0]
    payload = b[32:288]
    if payload.count(0xFF) != len(payload):
        if cur is None:
            cur = [addr, addr + 256]
        elif addr == cur[1]:
            cur[1] = addr + 256
        else:
            runs.append(cur); cur = [addr, addr + 256]
    elif cur is not None:
        runs.append(cur); cur = None
if cur is not None:
    runs.append(cur)

flags, famid = struct.unpack('<I', d[8:12])[0], struct.unpack('<I', d[28:32])[0]
print(f"familyID = 0x{famid:08X}  flags = 0x{flags:08X}")
for s, e in runs:
    print(f"  0x{s:06X} - 0x{e:06X}   ({e-s} bytes)")

sp, pc = struct.unpack('<II', d[32:40])
print(f"initial SP = 0x{sp:08X}   reset vector = 0x{pc:08X}")
```

Expected (and observed after the fix): data run starting at `0x001000`, a
plausible SRAM address for the initial stack pointer (`0x2000xxxx`), and a
Thumb-mode reset vector inside the code region.

This check was reused throughout the rest of the debugging process (Sections
5 and 6) to rule the partition table in or out whenever a new symptom
appeared, since it is a five-second check against the physical flash
contents rather than against source or build artifacts.

---

## 5. Bootloader defect: DFU button wired to the RESET pin

### 5.1 Symptom

After the partition fix, the board still never booted into the application.
`CURRENT.UF2`, read back as in Section 4.4, showed correct data starting at
`0x001000` with a plausible vector table -- so the firmware and partition
table were not the problem. The board stayed in DFU/mass-storage mode
indefinitely, and `dmesg`/`lsusb` on the host showed the drive
reconnecting after every flash attempt, never becoming a HID device.

### 5.2 Root cause

`Software/Adafruit_nRF52_Bootloader/src/boards/pca10056/board.h` (the board
used as the base for this bootloader port -- see
`BootloaderHackTutorial.md` for why `pca10056` rather than a dedicated board
name) originally set:

```c
#define BUTTON_1   _PINNUM(0, 18)  // P0.18 = RESET
```

`src/boards/boards.h` defaults `BUTTON_DFU` to `BUTTON_1`, and
`src/main.c` checks it unconditionally on every boot:

```c
dfu_start = dfu_start || button_pressed(BUTTON_DFU);
```

This check is independent of the double-reset mechanism. P0.18 sits on the
physical RESET button's net, which includes a debounce capacitor; the pin
reads low for a short time immediately after any reset. The bootloader
interpreted that as "DFU button held" and forced DFU entry on every single
boot, so the application was never reached regardless of how it was
flashed.

### 5.3 Fix

Both button pins were moved to P1.1, which per the schematic net-list
extraction (Section 7.1) is not broken out on the E73-2G4M08S1C module at
all -- guaranteed unconnected, and therefore reliably read high through the
internal pull-up:

```c
#define BUTTON_1   _PINNUM(1, 1)  // no connection on E73-2G4M08S1C module
#define BUTTON_2   _PINNUM(1, 1)  // no connection on E73-2G4M08S1C module
```

Rebuilt (`make BOARD=pca10056 SD_NAME=none clean && make BOARD=pca10056
SD_NAME=none all`) and reflashed via the bootloader's own self-update UF2
mechanism (see `BootloaderHackTutorial.md`, Section 5, for the self-update
procedure and its constraints).

### 5.4 Verification

Same `CURRENT.UF2` check as Section 4.4, confirming the application image
was untouched by the bootloader change. Functional confirmation: after a
single (not double) reset, the board stopped returning to DFU mode.

---

## 6. Firmware defect: 32.768 kHz crystal does not oscillate

### 6.1 Symptom

After the bootloader button fix, the bootloader correctly handed off to the
application -- but the board then enumerated nothing at all: no USB device
of any kind (not even the previous DFU drive), no BLE advertisement, no
LED activity.

### 6.2 Investigation

With the button-pin bug removed, `CURRENT.UF2` continued to show a correct
image at `0x001000`. The next step was to determine whether the application
was crashing, hanging, or simply not doing anything -- which requires
stopping the CPU and reading its actual state, not inferring it from
external symptoms. This was done over SWD (Raspberry Pi Pico running
`debugprobe`/`picoprobe` firmware, wired to J3 as described in
`BootloaderHackTutorial.md` Section 4) with OpenOCD, **without**
`nrf52_recover` (which would erase the chip):

```bash
openocd -f interface/cmsis-dap.cfg -f target/nrf52.cfg \
  -c "init" -c "halt" \
  -c "reg pc" -c "reg lr" \
  -c "mdw 0xE000ED04"   # ICSR
  -c "mdw 0xE000ED08"   # VTOR
  -c "mdw 0xE000ED28"   # CFSR
  -c "mdw 0xE000ED2C"   # HFSR
  -c "exit"
```

Result: `VTOR = 0x00001000` (vector table correctly relocated to the app),
`CFSR = 0`, `HFSR = 0` (no fault of any kind), `pc` inside the app's code
range. The CPU was not crashed. Sampling `pc` repeatedly with `resume`/
`halt` in between showed it parked at a single address across every sample.
Disassembling around that address (`mdh <addr-10> 12`) showed a `bf20`
(`WFE`) instruction immediately before it -- i.e. the CPU was asleep in the
kernel idle thread, which is normal Zephyr behavior when nothing is
scheduled, but abnormal this early after boot with BLE/USB configured in.

Peripheral register dump confirmed the application had stalled before
bringing up USB or the radio:

```bash
openocd -f interface/cmsis-dap.cfg -f target/nrf52.cfg -c "init" -c "halt" \
  -c "mdw 0x4000040C"   # CLOCK->HFCLKSTAT
  -c "mdw 0x40000418"   # CLOCK->LFCLKSTAT
  -c "mdw 0x40000518"   # CLOCK->LFCLKSRC
  -c "mdw 0x40027500"   # USBD->ENABLE
  -c "mdw 0x40027504"   # USBD->USBPULLUP
  -c "exit"
```

`USBD->ENABLE = 0` and `USBD->USBPULLUP = 0` (USB peripheral never turned
on, which is sufficient on its own to explain zero host-side enumeration).
`LFCLKSTAT = 0x00010000` (LFCLK reported running) with `LFCLKSRC = 1`
(XTAL requested) was the point that needed closer inspection: "running"
only reflects the currently-selected source having started at some point,
not that XTAL specifically ever locked, since RC can still be running from
an earlier fallback/reset state. NVIC state added the decisive detail:
`ISER0/ISPR0` showed RTC1 (system tick, IRQ 17) active and pending, but the
RADIO IRQ (IRQ 1, BLE controller) was not enabled at all, and RTC0 (the SDK
timer normally driven by BLE stack activity) stayed at zero across repeated
samples.

To settle whether the crystal itself was actually oscillating, independent
of any firmware's clock-selection logic, the clock hardware was driven
directly from a reset-halted state -- before MBR, bootloader, or
application code had touched anything:

```bash
openocd -f interface/cmsis-dap.cfg -f target/nrf52.cfg -c "init" \
  -c "reset halt" \
  -c "mdw 0x50000700"    # PIN_CNF[0], P0.00/XL1
  -c "mdw 0x50000704"    # PIN_CNF[1], P0.01/XL2
  -c "mdw 0x50000514"    # GPIO P0 DIR
  -c "mww 0x4000000C 1"  # CLOCK->TASKS_LFCLKSTOP
  -c "sleep 50"
  -c "mww 0x40000104 0"  # CLOCK->EVENTS_LFCLKSTARTED = 0
  -c "mww 0x40000518 1"  # CLOCK->LFCLKSRC = Xtal
  -c "mww 0x40000008 1"  # CLOCK->TASKS_LFCLKSTART
  -c "sleep 4000"
  -c "mdw 0x40000104"    # EVENTS_LFCLKSTARTED
  -c "mdw 0x40000418"    # LFCLKSTAT
  -c "reset run"
  -c "exit"
```

Result:

| Register | Value | Interpretation |
|---|---|---|
| `PIN_CNF[0]` (P0.00/XL1) | `0x00000002` | Input, disconnected -- reset default, not claimed as GPIO |
| `PIN_CNF[1]` (P0.01/XL2) | `0x00000002` | same |
| `GPIO P0 DIR` | `0x00000000` | no pin driven as output |
| `LFCLKSRCCOPY` | `1` | hardware accepted the XTAL source request |
| `EVENTS_LFCLKSTARTED` after 4 s | `0` | **crystal never started** |

The same procedure with `LFCLKSRC = 0` (RC) set `EVENTS_LFCLKSTARTED = 1`
immediately. The 32 MHz HFXO (tested the same way via `CLOCK->TASKS_HFCLKSTART`
and `HFCLKSTAT`) started and locked normally, so this is specific to the
32.768 kHz path, not a module- or power-level fault.

### 6.3 Root cause

The Y1 crystal is populated and correctly wired (module pins 11/13 = P0.00/
P0.01 = XL1/XL2, matching the E73-2G4M08S1C datasheet: "32.768KHz crystal
oscillator needs external connection"), but it does not oscillate on this
board revision. With XTAL requested (Zephyr's default,
`CONFIG_CLOCK_CONTROL_NRF_K32SRC_XTAL`), `LFCLK` never reaches a stable
state. Zephyr's Bluetooth controller blocks in `bt_enable()` waiting for a
stable low-frequency clock; `zmk_ble_init` runs as a Zephyr `SYS_INIT` at
`APPLICATION` level in the main initialization thread, so the entire
initialization chain after it stalls -- including the USB subsystem, which
is initialized later in the same sequence. The kernel itself is unaffected
(scheduler, system tick via RTC1, and later work still run), which is why
the CPU was observed cleanly parked in the idle thread rather than crashed
or hung in a spinloop.

The schematic carries a contemporaneous note ("Added missing diode. Should
fix crystal, VCCH") suggesting this crystal circuit has had prior issues on
this board revision; the load capacitors C9/C10 are 12 pF each, which is on
the low side for the XC32M4-32.768's rated 12.5 pF load capacitance and a
plausible contributor, though this was not isolated further since a working
fix (RC) was available.

### 6.4 Fix

`boards/tweetydabird/lotus58_ble/lotus58_ble_left_defconfig` and
`lotus58_ble_right_defconfig`, added:

```
CONFIG_CLOCK_CONTROL_NRF_K32SRC_RC=y
CONFIG_CLOCK_CONTROL_NRF_K32SRC_500PPM=y
```

This matches nice!nano's configuration for the same E73-2G4M08S1C module.
Trade-off: RC accuracy is roughly +/-250 ppm against the crystal's
roughly +/-20 ppm, and RC costs marginally more sleep current; neither is
significant for a BLE keyboard.

A related fix was applied on the bootloader side in the same investigation:
`Software/Adafruit_nRF52_Bootloader/src/boards/boards.c` had been changed
(during the same custom board bring-up that produced the button-pin bug in
Section 5) from the upstream default `CLOCK_LFCLKSRC_SRC_RC` to
`CLOCK_LFCLKSRC_SRC_Xtal`. This does not by itself explain the application
symptom (the bootloader hands off to the application well before the
`CONFIG_CLOCK_CONTROL_NRF_K32SRC_*` Kconfig even applies), but it silently
breaks the bootloader's own `app_timer` (driven by RTC1 off LFCLK), which
governs its 3-second "return to app if USB does not enumerate" timeout. It
was reverted to `CLOCK_LFCLKSRC_SRC_RC` and the bootloader rebuilt; see
`BootloaderHackTutorial.md`, Section 2.3, for the full writeup and why the
two candidate places to configure this (a bootloader `board.h` clock macro,
and an SDK SoftDevice-handler macro) are both dead code in this build
configuration.

### 6.5 Verification

Same physical test as in 6.2, repeated with `LFCLKSRC = 0`, confirming RC
starts within microseconds. Functional confirmation: with both the button
fix (Section 5) and the clock fix in place, the board enumerated as a USB
HID device (`lsusb`/`dmesg` showed a HID interface, not mass storage) and
became visible as a BLE peripheral.

---

## 7. Hardware findings not requiring a firmware change

### 7.1 Schematic net-list extraction

Several of the above investigations depended on knowing exactly which net
a given component or MCU pin is on, rather than trusting board-file
comments (which, per Sections 5 and 6, were themselves sometimes wrong).
This was done by parsing the KiCad schematic directly rather than opening
it manually: `wire`/`bus` segments, symbol pin positions (transformed by
each instance's placement/rotation/mirror), and label positions are unioned
into electrical nets via a small script that mirrors what a schematic ERC
tool does internally. Given a schematic and a reference designator, it
prints every net that designator participates in and every other pin/label
on each of those nets. This is the authoritative way to answer "what is
this pin actually connected to" for this board and is worth keeping for any
future hardware question, rather than re-deriving pin connectivity from
comments in board files.

### 7.2 P0.13 is not `SYSOFF`

A prior hypothesis (from an earlier hardware-porting document, not
reproduced here) suggested P0.13 might be tied to the charger's `SYSOFF`
pin, similar to a known nRF52840-DK `LED_PRIMARY_PIN` conflict. Net-list
extraction disproved this directly: P0.13 (module pin, `U7.33`) is on the
kscan matrix net (`Pin6` in `lotus58_ble.dtsi`); `SYSOFF` (`U1.15` on the
BQ24075) is on its own net together with the two power switches and a FET
gate, with no connection to any nRF52840 pin. No action needed.

### 7.3 Battery voltage ramping with no cell attached

Observed: probing the `+BATT` net with no battery connected shows the
voltage ramp up and down repeatedly, and LED1 (orange) blinks in the same
rhythm. Net-list extraction shows `+BATT` connects only to the battery
connector (J2.2), C4, and the BQ24075's `BAT` pins (U1.2/U1.3) -- no GPIO,
no firmware involvement. This is the charger IC's normal behavior with no
cell present: it attempts to charge the (essentially unloaded) net,
crosses its termination/detection threshold, backs off, and repeats. LED1
is directly driven by the same IC's `~CHG` output (`U1.9`), so it blinks in
sync for the same reason. Not a defect.

### 7.4 LED2 (blue) is wired with reversed polarity

Net-list extraction of LED2:

```
LED2.2 (anode)   -> R6 -> GND
LED2.1 (cathode) -> ZMK_LED (P1.10)
```

The anode is tied to GND through the series resistor, and the cathode goes
to the GPIO. This cannot conduct in either GPIO output state (driving
P1.10 low would need to pull it below GND; driving it high reverse-biases
the LED). For comparison, LED1 is wired the conventional way:
`VCC -> R2 -> anode -> cathode -> U1.9 (~CHG)`. Schematic and PCB layout
were confirmed to agree, so this is a board design defect, not a footprint
or fab mismatch. LED2 cannot be made to light with any firmware or
bootloader change; a PCB rework (swapping the two pads, or bridging around
them) would be required. This has no effect on keyboard function and was
left as-is.

---

## 8. Current status

- Left half: boots the application, enumerates as USB HID, advertises over
  BLE. Verified with the fixes from Sections 4, 5, and 6 all applied.
- Right half: identical devicetree/defconfig changes applied (Sections 4
  and 6 affect both `lotus58_ble_left` and `lotus58_ble_right` files
  symmetrically); the bootloader fix (Section 5) is per-chip and must be
  reflashed on the right half's bootloader independently the same way it
  was on the left. Not yet verified at time of writing -- only the left
  board was connected during this debugging pass.
- Bootloader binaries current as of this document:
  `Software/Binaries/lotus58_ble_bootloader_nosd.hex` (SWD flash) and
  `Software/Binaries/lotus58_ble_bootloader_update.uf2` (self-update UF2),
  both built from `Adafruit_nRF52_Bootloader` with the Section 5 and
  Section 6 fixes applied. Rebuild after any further `board.h`/`boards.c`/
  Makefile change; these files are not regenerated automatically.
- LED2 remains non-functional (Section 7.4); requires a PCB rework, not a
  firmware change.
- Carried forward from Section 3 as still out of scope: ZMK Studio (needs
  physical key-position data on the physical layout node), the commented-out
  rotary encoder and nice!view display nodes (unverified against this PCB
  revision).
- If the crystal circuit is reworked later (Section 6.3), reverify with the
  Section 6.2 direct-register procedure before switching
  `CONFIG_CLOCK_CONTROL_NRF_K32SRC_*` back to `XTAL` -- it is a five-second
  check and avoids re-introducing Section 6's failure mode blind.
