# AutoItemMacro

A general-purpose consumable macro generator for World of Warcraft.

Define named macro presets, each with a priority-ordered list of items. AutoItemMacro
generates a real WoW macro that always `/use`s the highest-priority item currently in
your bags — so one macro button can serve as "best available healthstone", "best
available flask", "best available utility potion", etc., without manual upkeep as you
loot or buy replacements.

---

## How it works

- Each preset has an ordered list of items (drag & drop from bags, or add by item ID).
- The generated macro shows a `/use` line per item, in priority order. WoW executes the
  first `/use` that is valid (item present, not on cooldown) and ignores the rest — so
  shared-cooldown consumables (potions, healthstones, …) resolve correctly, while
  single-use items like flasks/food just use the first one found in bags.
- Items can optionally be bound to a modifier key (`[mod:alt]`, `[mod:ctrl]`,
  `[mod:shift]`, `[mod:nomod]`) instead of always firing.
- Macros are kept in sync automatically on bag changes (toggleable), and can be
  force-updated on demand.

---

## Usage

Open the preset editor with `/aim`, the minimap button, or the AutoItemMacro entry in
the addon compartment next to the minimap.

- **+ New Macro Preset** — create a new named macro
- Drag an item from your bags onto the drop zone, or type an item ID and click Add
- Reorder items with the up/down buttons; priority = order in the list
- Click the modifier badge to cycle `--- / ALT / CTL / SHF / NOM`
- The macro body preview updates live as you edit

The minimap button drags around the minimap ring and remembers where you put it.
Untick **Minimap button** at the bottom of the editor to hide it; the compartment
entry and `/aim` still work.

New presets are named `aim_macro1`, `aim_macro2`, … so the macros this addon owns are
easy to spot in the game's macro list. Rename them to anything you like — the prefix
applies only to the generated defaults.

Other commands:

- `/aim update` — force-update all macro presets immediately
- `/aim help` — show command help

> **Combat note:** Macros cannot be edited during combat. The editor window auto-hides
> when combat starts, and any pending auto-update runs as soon as combat ends.

---

## Feedback & bugs

Please report issues on the GitHub repository.
