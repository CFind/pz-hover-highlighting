# Done

## TASK-004: Disable key-held activation by default
**Priority:** P2
**Tags:** options, keybinding
**Updated:** 2026-10-14 20:47

Make Require key press default to off so an update preserves the mod's familiar unconditional hover behavior unless players opt into key-held activation.

### Plan

Changed the fresh-setting fallback to unchecked, updated the behavioral regression and technical notes, and preserved the existing saved-setting/runtime paths. The full Lua test set, syntax/data checks, pzstudio build, and package-content comparison passed; in-game acceptance remains open.

---

## TASK-003: Restrict highlights to the player's Z-level
**Priority:** P2
**Tags:** highlighting, z-level
**Updated:** 2026-10-14 20:29

Prevent direct picks and cursor-area scans from highlighting objects on another level, and immediately clear active highlights when the player changes levels.

### Plan

Kept the player's integer Z-level authoritative for direct picks and cursor-area scans, added immediate cleanup for highlights on a different level, documented the invariant, and added red-green Lua coverage. The full Lua test set, syntax/data checks, pzstudio build, and package-content comparison passed; in-game acceptance remains open.

---

## TASK-002: Add key-held activation mode
**Priority:** P2
**Tags:** options, keybinding
**Updated:** 2026-10-11 22:40

Added a default-on activation mode that requires a configurable vanilla keybinding to be held while hover highlighting is active.

### Plan

Implemented the vanilla `HoverHighlighting Activation` binding with a Tab default, the `Require key press` Mod Option, immediate key-up cleanup, translations, focused Lua coverage, and technical documentation. Lua syntax, behavioral test, JSON, diff, pzstudio build, and package-content checks passed; in-game acceptance remains open.

---

## TASK-001: Move highlight color to in-game mod options
**Priority:** P2
**Tags:** options, color
**Updated:** 2026-10-01 21:27

Replaced the three sandbox RGB settings with one client color picker under Options → Mods. Preserved the neutral gray default and updated active highlights when a new color is accepted.

### Plan

Implemented the color picker and saved setting, removed sandbox definitions, updated the project notes, and passed Lua syntax, JSON, isolated package, and deployed pzstudio build checks. In-game acceptance remains to be checked.

---
