# Veilfall: Triune

0.6.15 — work in progress. Not a finished assistant.

Suite AutoRun:

```
/lua run vf
```

Inventory only:

```
/lua run vfi
```

Headline is the suite number (`lua/vft/version.txt`). Inventory Check uses `lua/vft/inv/version.txt` — same `0.6.N` family. Inv snapshots bump both files to the next patch; suite-only snapshots bump only the suite file, so `/lua run vfi` stays on the last inventory release. Overlay: Manager Update plants vf.lua + vfi.lua + vft; Inventory Update plants vfi.lua and inv modules only.
