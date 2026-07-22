# bit_force

A 2D pixel-art game built with the [Usagi](https://usagiengine.com) engine (Lua 5.5).
The full engine reference is in [USAGI.md](USAGI.md) — consult it for exact API
signatures. This file covers the conventions and footguns that matter when
editing this project.

## Commands

- `usagi dev` — run with live reload (edits to `.lua`, sprites, sfx, and `data/`
  apply on save without losing state). Primary dev loop.
- `usagi run` — run without live reload (`usagi.IS_DEV` is false).
- `usagi tools` — jukebox, tile picker, save inspector, color palette.
- `usagi export` — package for Linux/macOS/Windows/web + a portable `.usagi`.
- `usagi refresh` — regenerate LSP stubs and docs (`meta/usagi.lua`,
  `.luarc.json`, `USAGI.md`) after upgrading the binary. Does not touch `main.lua`.

Run from the project root; the path arg is optional.

## Layout

- `main.lua` — entry point (`_config` / `_init` / `_update` / `_draw`). Currently
  the default stub.
- `data/` — game data, read with `usagi.read_json("x.json")` / `usagi.read_text`.
- `sfx/` — `.wav` files; stem is the name (`sfx.play("jump")`).
- `music/` — `.ogg`/`.mp3`/`.wav`/`.flac`; stem is the name. OGG preferred.
- `meta/usagi.lua` — LSP type stubs. Generated; do not edit.
- Optional drop-ins at root: `sprites.png` (16×16 grid), `palette.png`,
  `font.png`, `shaders/`.
- Split code with `require "name"` (resolves `name.lua` then `name/init.lua`).
  **Never** use `loadfile`/`dofile`/`io` for `.lua` — those break in web/exported
  builds. `require` goes through the virtual filesystem and works everywhere.

## Live-reload rules (the #1 thing to get right)

Every `.lua` chunk re-executes on save, so top-level `local`s are re-bound each
reload. To survive reloads:

- **Mutable game state → one capitalized global**, conventionally `State`,
  assigned only in `_init`. A `local State` at module scope would reset every save
  and wipe the running game.
- **Constants → file-scope `local`** in `SCREAMING_SNAKE_CASE`.
- **Modules → `local Foo = require("foo")`**, or a capitalized global if you want
  it reachable everywhere.

`_init()` runs at startup and on **hard reset only** (F5 / Ctrl+R), *not* on a
save-triggered reload. Saving preserves `State`; F5 rebuilds it.

## Style

- 2-space indent, `snake_case` for locals / functions / table fields.
- `SCREAMING_SNAKE_CASE` for file-scope constants.
- **`Capitalized`** for cross-frame globals (`State`, `Player`, ...).
- `.luarc.json` enables `lowercase-global`: any unguarded lowercase assignment at
  file scope is a lint error — it means you forgot `local`. Capitalize it only if
  you genuinely want a global.
- Engine tables (`gfx`, `input`, `sfx`, `music`, `usagi`, `util`, `effect`) stay
  lowercase and are exempt via the meta stubs.

## API notes

- **1-based indexing** throughout: `gfx.spr(1, ...)` is the top-left sprite;
  `gfx.COLOR_BLACK` is 1, `gfx.COLOR_RED` is 9 (Pico-8 numbering shifted +1).
- Colors are palette **slot indices**, not RGB. Use `gfx.COLOR_*` constants. Use
  `gfx.COLOR_TRUE_WHITE` as the identity tint for `spr_ex`/`sspr_ex`.
- Draw calls take an optional trailing `alpha` (0..1). `_ex` variants pack all
  power-args into one fixed signature (all args required).
- No scale param on `spr`; scale via `sspr_ex` with a different destination size.
- Prefer abstract input actions (`input.pressed(input.BTN1)`, `input.held`, ...)
  over raw `input.key_*` — actions honor player remaps and work on gamepad.
- Save with `usagi.save(t)` / `usagi.load()`; requires `game_id` in `_config`.
  Table keys must be all-string or a dense `1..n` array (no sparse int keys).
- Juice: `effect.hitstop / screen_shake / flash / slow_mo`. Math/geometry helpers
  in `util.*`.

## Compound assignment

A preprocessor adds `+=  -=  *=  /=  %=`. Two limits:
- Line-anchored: `if c then x += 1 end` is left as-is — use longhand.
- LHS is duplicated verbatim: `t[f()] += 1` calls `f()` twice.

## Debugging

- Fastest loop is `print` in `_update`/`_draw` under live reload.
- `print(usagi.dump(t))` pretty-prints tables (`print(t)` shows only an address).
- `assert(cond, msg)` / `error(msg)` surface to the in-game red error overlay in
  dev. Lua fails silently on nil several frames downstream, so assert assumptions
  in `_init` and at function boundaries.
- `USAGI_VERBOSE=1` prints a startup snapshot + per-second frame timing.

## Config caveat

`_config()` is read **once at startup and cached** — editing it while running
won't update the title/resolution/etc. Restart the session to pick up changes.
