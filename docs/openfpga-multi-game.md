# Listing several games from one openFPGA core

A core that plays more than one game usually starts life with a single ROM data
slot: the user browses to `punchout.rom` or `spnchout.rom`, and the core works
out which is which. It plays fine, and it is invisible. The Pocket's menu shows
one entry, and an updater like **pupdate**, which reads the core's own metadata
off the card, reports exactly one supported game — because one is all the
metadata declares.

The fix is a documented openFPGA feature called an **instance JSON**: a small
file per game that names which files fill which data slots. The Pocket browses
those files instead of raw ROMs, so each game appears by name.

This is how the CPS cores do it, and it is worth copying verbatim rather than
inventing something.

## The shape

Three data slots and a folder of small JSON files:

```
Assets/<platform>/
    common/                       the images themselves
        punchout.rom
        spnchout.rom
        armwrest.rom
    <author>.<core>/              one file per game -- this is the menu
        Punch-Out!! (Rev B).json
        Super Punch-Out!!.json
        Arm Wrestling.json
```

`data.json` declares the slots, but only slot 0 has a filename policy of its
own; slots 1 and 2 are filled by whichever instance file the user picks.

```json
{ "name": "Arcade Game", "id": 0, "required": true,
  "parameters": "0x113", "extensions": ["json"], "address": "" },

{ "name": "ROM",         "id": 1, "required": true,
  "parameters": "0x108", "extensions": ["rom"],  "address": "0x00000000" },

{ "name": "Records",     "id": 2, "required": false, "nonvolatile": true,
  "parameters": "0x22",  "extensions": ["sav"],  "address": "0x20000000",
  "size_maximum": "0x400" }
```

The parameter words are bitmaps, and the bits that matter here are:

| bit | meaning | where it is used |
|-----|---------|------------------|
| 0 | user-reloadable from the core menu | slot 0, so a game can be switched without leaving the core |
| 1 | core-specific file | slot 0, which puts the instance files in `Assets/<platform>/<author>.<core>/` rather than `common/` |
| 3 | read-only | slot 1 |
| 4 | **treat a loaded JSON as an instance description** | slot 0 — this is the whole feature |
| 5 | create nonvolatile data as 0xFF if absent | slot 2, so a first run has a save file to write to |
| 8 | full core reload, bitstream included | slots 0 and 1, so switching game restarts cleanly |
| 25:24 | platform index into `platform_ids` | only if a slot's file lives under a second platform |

Slot 0's `address` is the empty string. The instance file is consumed by the
Pocket's firmware and never reaches the core.

An instance file is then just a mapping:

```json
{ "instance": {
    "magic": "APF_VER_1",
    "variant_select": { "id": 0, "select": false },
    "data_path": "",
    "data_slots": [
      { "id": 1, "filename": "punchout.rom" },
      { "id": 2, "filename": "punchout.sav" }
    ]
} }
```

`data_path` is a subfolder inside `common/`; empty means `common/` itself. An
instance may also carry `memory_writes`, which push per-game constants into the
core's address space — useful when games differ by more than their ROM.

Finally, set the platform's category so the Pocket files it correctly:

```json
{ "platform": { "category": "Arcade Multi", "name": "...",
                "year": 1984, "manufacturer": "..." } }
```

## The part that silently breaks

**Adding slot 0 renumbers everything after it.** The ROM that used to arrive in
slot 0 now arrives in slot 1, and the save moves from 1 to 2. Any core logic
that names a slot by number has to move with it, and nothing will warn you:

- Game detection that watches the announced size —
  `dataslot_requestwrite_id == 0` becomes `== 1`. Left alone it now measures
  the instance JSON, a few hundred bytes, and every game detects as whatever
  the mismatch happens to select.
- Core-initiated saves — `target_dataslot_id` moves from 1 to 2. Left alone the
  core writes its save over the ROM slot.

Both compile, both pass simulation if the bench drives the core directly rather
than through the APF bridge, and both fail only on hardware.

## Two things not to use

**`variants.json`.** It looks exactly right — "up to 8 core variations… very
similar hardware with just a few asset changes" — but Analogue's own
documentation calls it an upcoming feature and says nothing about how a variant
is presented to the user. Shipping cores that clearly could use it ship it
empty (`"variant_list": []`), which is the strongest available hint. Instance
files carry a `variant_select` field; set `"select": false`.

**Extra ROM slots, one per game.** The obvious-looking alternative — declare
`spnchout.rom` and `armwrest.rom` as their own slots so tools can see them —
loads every one of those files whose file is present, in order, to the same
address. The last one wins, so a user with all three ROMs on the card gets
whichever game sorts last, regardless of what they picked.

## What you get besides the listing

Per-game saves come free: each instance names its own `.sav`, so records stop
sharing one file. Keeping the first game's filename identical to the old
single-slot name means existing users keep their records.

## Checklist

1. `data.json`: instance slot 0 (`0x113`, extension `json`, empty address), ROM
   slot 1, nonvolatile slot 2.
2. `Assets/<platform>/<author>.<core>/<Game Name>.json`, one per game.
3. Platform category `Arcade Multi`.
4. **Renumber every slot id in the core's own logic**, and grep for the old
   numbers rather than trusting memory.
5. Make packaging fail if an instance file is missing — a dropped file reads as
   a missing game, which looks like a core bug rather than a packaging one.
6. Test on hardware. None of this is reachable from a simulation bench that
   instantiates the core directly, because all of it lives in the APF bridge.
