# Agent constraints — Triune Assistant / TA

Things you cannot derive from the code and will get wrong by default. Everything
else lives in `docs/`. **Current state, plans, mode/UI behavior and the known-bug
list are in `docs/STATUS.md`** — read it when you need orientation.

Keep this file short. If a note is history, status, or a changelog entry, it goes
in `docs/STATUS.md`, not here.

## The tree

Live play is **VF** (`/lua run vf`), not stock Triune.

| What | Where |
|---|---|
| **Edit copy — what `/lua run vf` loads** | `_live/` (junction to that install's MQ `lua` folder, `tools/link-live.ps1`) |
| **Snapshot — do not edit while testing** | `lua/` |
| Live loadout | MQ `config/{server}_{char}.lua`, name lowercased (Belvue: `multiclass_belvue.lua`) |
| Spell dump | MQ `config/ta_data.lua` — still the `ta_` name, there is no `vft_data.lua` |
| Shared routes | MQ `config/{zone}_routes.lua` |
| Toon store (locks, powersource, clickies) | MQ `config/{server}_{char}.ini`, `vft/toonini.lua` |
| Cross-VM IPC | MQ `config/vf_*.txt`, `vft/ipc.lua` |

**More than one server is in play** — `multiclass`, `veilfall`, `ascendant`,
`lineage`, `Perky Crew` all have live config. Never assume one.

**Edit `_live/`.** Do not edit `lua/` here, and do not copy either direction,
until they say the test is good (`save` / `snapshot` / `lock it in`). `lua/` is
the git snapshot, not what MQ is running. `_live` is gitignored.

Do not rebase or PR to gennro. Do not duplicate MQ's own files into this repo.

Git tracks the snapshot (`vf.lua`, `vft.lua`, `vfup.lua`, `vft/`). No `vfti.lua`,
no `ta.lua`, no `tools/` (those stay on the box). `/lua run vfup` overlays that
set from GitHub `main` onto `mq.luaDir` and never writes `vft/config` ini; it
does not reload. Inventory is a satellite: `/lua run vft/inv` still works
without the engine. **`toonini.lua` must keep requiring only `mq`**; giving it a
`vft.util` dependency drags the engine into that standalone path.

## Server rules (custom emu — do not assume live EQ behavior)

Three house rules that invalidate normal EQ assumptions. Check any plan against
them; reasoning from stock EQ produces work that looks right and is not.

1. **One character has both bard songs and caster spells,** so **class is not a
   proxy for cast mechanics.** A row tagged `cls = 'Brd'` may hold a caster spell
   that must be stood still for, and vice versa. Ask the *spell's* skill
   (`mq.TLO.Spell(name).Skill()` → `runtime.bardCastSkill`), never `g.cls`.
2. **Buffs never drop** — not on a timer, not on song expiry. Bard buff songs
   land, tick down, sit at a **no-time state**, then reset as if they just
   landed. Zoning is the only boundary found so far. So a missing-buff row is
   cast once per zone and then permanently satisfied, re-buff polling after that
   is waste, and **nothing must re-sing a buff song that is already up** (rule 3
   is why that is dangerous, not merely wasteful). Detection is only safe on the
   bar-scan path, which matches by name after stripping the `:<duration>`
   suffix; asking `Duration() > 0` reads a no-time effect as absent.
3. **Singing a DoT or direct-damage song locks the spell bar** until you cast
   something else or `/stopsong`. It does not clear on its own. Buff songs do not
   do this; only the damage lines. Because `isCasting()` is just
   `Me.Casting.ID() > 0` and the gem loop is gated on it, a held lock can stall
   **all** TA casting for every class. Do not re-enable a bard damage song
   without `runtime.songBarHeld()` in play.

## Writing Lua here

MQ2Lua is **Lua 5.4**, so a chunk gets **200 locals**. `vf.lua` is at ~139 (98
of them `local function`), which is room but not much given its size — prefer
hanging new helpers on `runtime`. A handful of locals is fine; a new family of
them is not. `check-lua.ps1` gives you the real number the moment you overflow.

**Never register a TLO to talk between scripts.** `mq.AddTopLevelObject` holds a
C callback over the owning Lua state; `/lua stop` frees that state without
unregistering, and the next read from the other VM takes the client down. Not
catchable with `pcall`. Use `vft/ipc.lua` (`key=value` files). Liveness is "the
tick field stopped changing", never a clock difference across VMs.
`_live/examples/datatypes.lua` demonstrates the TLO approach and is a trap here.

**Config writes go through `U.writeTable`** — serialize to `.tmp`, prove it
loads, then swap, keeping one `.old`. `io.open(path, 'w')` truncates first, so a
crash mid-write loses the file. One loadout per character; **no profiles**.

**Debug logs must be gated and capped** at the writer, not the call site.
`walk.W.log` grew `ta_rush.log` to 76MB because two callers forgot the gate.

**Console tag:** `require('vft.chat')` — `chat.say('Inv', msg)` / `chat.err(...)`
prints themed `[VF:<module>]` (start with Inv; reuse for Mgr etc.).

**Compile-check before you tell them to reload:**

```
powershell -File tools/check-lua.ps1            # _live
powershell -File tools/check-lua.ps1 -Path lua  # snapshot
```

It catches the 200-local overflow with a line number instead of letting it land
as a silent non-load in game. Needs a 5.4 `luac` (found automatically, or set
`TA_LUAC`). Ignore `_live/tools/luacheck_syntax.py`; it targets the wrong Lua.

**Pure logic can be tested offline — you do not need the game.** There is a real
5.4 interpreter at `%LOCALAPPDATA%\Programs\Lua\bin\lua.exe`, and `tools/test-*.lua`
run against `_live/` with `package.loaded['mq']` stubbed. Use it for anything
that is just data in, data out (serializers, ini writers, gates):

```
& "$env:LOCALAPPDATA\Programs\Lua\bin\lua.exe" tools/test-serializer.lua
```

**Snapshot with the script, never by hand** — and only once they say the test is
good. It compile-checks `_live`, refuses to copy on failure, mirrors only the
TA-owned entries, then re-checks `lua/`.

```
python tools/snapshot.py            # _live -> lua, the normal case
python tools/snapshot.py --dry-run  # what would change
python tools/snapshot.py --restore  # lua -> _live, roll live back
```

## Do not guess at a TLO — grep the mirrors

| Path | What |
|---|---|
| `G:\EQEMU\mq-docs` | `macroquest/docs`, ~558 markdown files — prose, plugin docs, command syntax |
| `G:\EQEMU\mq-definitions` | `macroquest/mq-definitions`, LuaLS annotations — **exact** signatures, return types, enums |

`mq-definitions` is authoritative and often more complete than the website: the
published `Me.CombatState` page lists five values, `mq/datatype/_character.lua`
lists six. Plugin **sources** are cloned at `G:\EQEMU\mq-plugin-src` (~2500
files — it is populated; read it before concluding a plugin's behavior is
unknowable). All three are shallow clones; `git pull` to refresh.

## Comments

One line, prefixed `-- VF:`, greppable. `rg "VF:"` is the index.

Say the constraint, not the history. No paragraphs of reasoning, no "the old code
used to", no phase numbers, no source-line citations, no apologies to the
reviewer. If it needs more than a line it belongs in `docs/`, and the comment
points at the doc. Delete stale prose when you touch the function.

## How they reload

```
/vf pause
/lua stop vf
/lua stop vft/inv
/lua run vf
```

Then `/vf start` or `/vfrun`. Manager: `/lua run vft/mgr` or `/vfmgr`.
Inventory (standalone OK): `/lua run vft/inv` or `/vf inv` / `/vfinv`.
Combat daemon state: `/vfc`. Do not `/lua run vft/inv/app` — that is a module,
not an entry script.

**The engine file is `vf.lua`; the module directory is still `vft/`.** VFT means
VeilFall Triune and the directory keeps it, so satellites stay `/lua run vft/inv`,
`vft/mgr`, `vft/fight`, `vft/waypoints`, and every `require` stays `vft.*`.

`vft.lua` and `ta.lua` are five-line shims that print a notice and run
`/lua run vf`. That is why AutoRun never has to change.

Other live binds, not all documented in `docs/`: `/vfvault`, `/vfmapnav`,
`/vfmappoint`, `/assgui`, `/assend`, `/extend`, `/extwin`, `/stopbuffbeg`.
`rg "bind\('/" _live` is the real list. The `/ta*` names are retired — `/ta` never
worked anyway, EQ expands it to `/target`.

## Do not

- Edit `lua/`, or copy live ↔ snapshot, before they say the test is good
- Treat `lua/` as what MQ is running — it is not
- Hardcode a drive letter or machine-specific install path in shipped code. Use
  `mq.configDir`, `_live.target`, or an env var
- `git init` this repo, or rebase / PR to gennro
- Switch AutoRun off `/lua run vft` — it still works, `vft.lua` is a shim to `vf`
- Paste settings into `vf.lua`, or rewrite the tick, unless asked
- Refactor `castGem` or the bard song code before the MQ2Cast / MQ2Twist decision
  in `docs/PLUGIN_AUDIT.md`. That is the exact mistake we made with movement
- Reintroduce a `/keypress` forward-hold as a movement fallback
- Re-add route-derived camps (`docs/ANCHOR.md`)
- Fix the bugs in `docs/STATUS.md` as drive-bys — each belongs to a phase and
  needs its own live test
- Restore `_archive/ta-fork-pre-rebrand/` as the boot engine
- Add a Manager setting that a second setting already answers. Three separate
  keys fed "rest for mana" and two fed "am I in panic"; both cost a live bug.
  Before adding a knob, `rg` for an existing owner — and before deleting one,
  `rg` the **whole** tree, not just `vf.lua`

`docs/MOVE_REFACTOR.md` phases 0–3 are **done**; only optional phase 4 remains,
and its phases are behavior-preserving by definition — a behavior change is not
a phase. The doc's own header still claims 3 is unstarted; it is not.
