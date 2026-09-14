# Veilfall: Triune

0.6.17.2 — work in progress. Not a finished assistant.

Suite AutoRun:

```
/lua run vf
```

Inventory only:

```
/lua run vfi
```

Headline is the suite number (`lua/vft/version.txt`). Inventory Check uses `lua/vft/inv/version.txt` — same family (`0.6.N` on main, `0.6.N.B` on beta). Inv snapshots bump both files to the next number; suite-only snapshots bump only the suite file, so `/lua run vfi` stays on the last inventory release. Overlay: Manager Update plants vf.lua + vfi.lua + vft; Inventory Update plants vfi.lua and inv modules only.
