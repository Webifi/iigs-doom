# Apple IIe keyboard compatibility

A “stealth” IIgs uses the Apple IIe keyboard on the ROM 00/01 board's J13 header. Doom selects its compatibility keyboard reader at startup if the usual ADB keyboard at address 2 does not answer an identification request. This is an absence-based fallback, not a positive J13 detector. Hold **K** while Doom starts to force compatibility mode, including when an ADB keyboard is also attached.

The normal ADB reader and its per-frame instruction stream are unchanged. The fallback uses the IIgs keyboard registers and the same game key setup and menu code. It reads one ordinary key and the modifier keys. Upper/lowercase letters and shifted punctuation share bindings. Arrow keys, Return, Escape, Delete, Tab, numbers, letters, and punctuation work for menus and key setup.

In compatibility mode the default **open Apple fires**, **closed Apple strafes**, and **Shift or Caps Lock runs**. Use these modifiers with a movement or turning key. Control remains a fire binding, but Apple documented a Control/Shift reporting defect during key repeat; open Apple avoids that documented ambiguity through the button inputs. Existing saved key settings take precedence; use the key setup or reset its defaults if an old configuration binds open Apple differently.

The interface cannot report individual releases of overlapping ordinary keys. Doom keeps the latest ordinary key down until another character replaces it or all ordinary keys are released. Release ordinary keys before changing chords; pressing W and Left together is not equivalent to an ADB keyboard. Fire, run and strafe modifiers can be held independently alongside an ordinary key. Firmware repeat is ignored as an extra press; the game supplies its menu repeat.

Several control combinations are indistinguishable from navigation characters. The navigation meaning wins: Control-H is Left, Control-I Tab, Control-J Down, Control-K Up, Control-M Return, Control-U Right, Control-[ Escape. This also limits which physical combinations can be separately bound. There are no guessed release timers.

A stock ROM 03 board has no J13 header or keyboard matrix wiring. The fallback register interface can be tested on ROM 03 with an ADB keyboard or a register fixture, but native J13 on ROM 03 would require additional hardware. Current MAME tests using register injection validate the software interface, not a physical J13 keyboard or its rollover. Physical ROM01 validation remains necessary.

Primary references: Apple IIgs Hardware Reference, second edition, pp9 and 125–132; ROM01 and ROM03 motherboard schematics, sheet 5; Apple IIgs Firmware Reference pp189–196; Apple technical notes 58 and 71. The complete sourced report and visual evidence are in `/Users/john/dev/iigs-hardware-research/iigs-board/stealth-keyboard.stealthkb.md`.

## Implementation

`i_stealth65.s` lives at `$04:7500` after ENDOOM, with its state in the same initialized RAM section. On ordinary ADB systems only the startup selector runs. In compatibility mode it patches the existing two `I_StartTic` call operands to a wrapper, and prevents raw keyboard Talks while leaving ADB mouse service active. The wrapper reads `$E0C000` before acknowledging `$E0C010`, combines `$C025` modifiers with `$C061/$C062` Apple buttons, and queues synthetic key transitions for the existing consumer.

Before reading or acknowledging a key it reserves space for the maximum eight transitions: five modifier changes, the previous ordinary key up, a new key down, and a quick-tap key up. Queue writes are atomic against the IRQ producer. If fewer than eight slots are free, the reader keeps its old state and leaves the hardware strobe pending. Every emitted down/up pair follows the game's existing at-least-one-tic rule; menus and key binding therefore use the same events as the ADB route.
