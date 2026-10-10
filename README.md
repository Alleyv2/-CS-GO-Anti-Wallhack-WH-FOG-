# wh_fog

Anti-wallhack fog of war for SourceMod.

Hides an enemy only when a wall fully blocks their body.
If any part of them is visible, they show up normally.

---

## Features

- 15-ray check (3x5 grid) on the enemy body
- Enemy is hidden only if **all** rays are blocked
- Close-range fights are not affected
- Enemy shows up for a few seconds after they damage you
- Also hides the enemy's weapon
- Works only for living players
- Config file: `configs/wh_fog.cfg`

---

## Install

1. Put `wh_fog.smx` in:
   ```
   addons/sourcemod/plugins/
   ```
2. Start the server or run:
   ```
   sm plugins load wh_fog
   ```

---

## ConVars

| ConVar | Default | What it does |
|---|---|---|
| `wh_fog_enabled` | `1` | Turn the plugin on/off |
| `wh_fog_min_dist` | `64.0` | Always show enemies closer than this |
| `wh_fog_dist` | `0.0` | Only hide enemies further than this. `0` = always |
| `wh_fog_far_dist` | `0.0` | Long-range tightening. `0` = off |
| `wh_fog_far_rays` | `15` | Rays needed past `far_dist` (1–15) |
| `wh_fog_reveal_damage` | `1` | Show enemy after they damage you |
| `wh_fog_reveal_time` | `3.0` | Seconds they stay visible |
| `wh_fog_hide_weapons` | `1` | Hide their weapon too |
| `wh_fog_alive_only` | `1` | Only hide for living viewers |
| `wh_fog_debug` | `0` | Log hide/show decisions |

---

## Commands

| Command | What it does |
|---|---|
| `sm_whfog_status` | Show which enemies are hidden from you and why |
| `sm_whfog_refresh` | Clear cache and re-read the config |

Both need `ADMFLAG_GENERIC`.

---

## Build

```
spcomp wh_fog.sp
```

---

## Author

**Alley** — https://github.com/Alleyv2
