# Pasar Brainrot — roblox-brainrot-01

[![make.fun bounty](https://make.fun/badge/roblox-brainrot-01.svg)](https://make.fun)
[![rank](https://make.fun/badge/roblox-brainrot-01/dillahhhh/roblox-brainrot-01-entry-v5/rank.svg)](https://make.fun)
[![reward](https://make.fun/badge/roblox-brainrot-01/dillahhhh/roblox-brainrot-01-entry-v5/reward.svg)](https://make.fun)

"Pasar Brainrot" is a Steal-a-Brainrot game for [make.fun](https://make.fun)'s
"Make the best AI Roblox brainrot game" bounty (roblox-brainrot-01): a 3D night
market in Nusantara style where players collect absurd Brainrot characters that
earn money every second, keep them on their own base, climb the rarity ladder,
steal from other players, and survive the periodic Pasar Tumpah flood that
sweeps the map and drops claimable crates.

- `main.ts` (Node 22, standard library only) hands the game in: it copies
  `game.rbxl`, `src/`, `screenshots/` and `PLAY.json` to `/output`, leaving out
  every name that starts with a dot, and writes `/output/dossier.json` with
  `vendor/makefun-roblox.ts`, the kit's copy, unchanged.
- `game.rbxl` is the place Rojo builds from `src/` and `default.project.json`.
  The world (terrain, conveyor, plaza, 8 player bases, gates, city, trees,
  street lamps) is built at runtime by `src/server/Main.server.luau`.
- `src/shared/Config.luau` is the single source of truth for the Brainrot
  roster (7 rarities), economy, flood, steal, and DataStore constants.
- `PLAY.json` names the published Public place
  (place 112415374628095, universe 10777368274).
- `screenshots/` currently holds the kit starter's placeholder captures;
  they will be replaced with real Studio captures of this game before submit.
- One of the screenshots must also be the game's first thumbnail on Roblox:
  the same picture, uploaded on the Creator Dashboard with the game's icon.

Run it as the grader does, writing `out/` in place of `/output`:

    mkdir -p out && MAKEFUN_OUTPUT_DIR=out node main.ts

The rules are on the bounty's page (/bounty/roblox-brainrot-01) and in the
kit's RULES.txt, which gives every command in order (Before you submit,
then Enter).
