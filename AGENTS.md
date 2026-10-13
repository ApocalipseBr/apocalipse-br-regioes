# ApocalipseBR Regions contributor guide

## Identity and layout

This is a Project Zomboid Build 42 region management mod. The repository root is
the PZ Studio project. `project.json` owns Workshop metadata; Workshop item ID
is `3706462687`. The source/package folder is `Apocalipsebr-regions`, while the
existing game mod ID is `ApocalipseBR_Regioes`. Preserve both identifiers.

- `Apocalipsebr-regions/42.18/media` is the latest implementation and the target
  for future work. The user explicitly requested latest-version-only changes.
  Keep historical `42.14` files unless explicitly asked to change them. If a
  newer version folder is added, target that latest folder instead.
- `Apocalipsebr-regions/common` currently has no shared implementation.
- Top-level `Apocalipsebr-regions/media` contains older scream assets/options and
  translations. It is not the main region implementation. Keep duplicated
  sandbox definitions only when explicitly working on that older tree.
- `Workshop/preview.png` and `Workshop/description.txt` are source Workshop
  assets. The capital W matters on Linux. The build wrapper explicitly copies
  the preview and description because PZ Studio looks for lowercase `workshop`.

## Region lifecycle and authority

- Shared `RegionManager_Config.lua` defines categories, example regions, paths,
  type annotations, and logging. `RegionManager_JSON.lua` supplies JSON support.
- Server `RegionManager_Server.lua` loads `RegionManager_Regions.txt` through
  game file APIs (relative to the Zomboid data directory). Missing files receive
  configured defaults. Category properties are merged with custom overrides.
  Admin commands add, update, delete, import, and export regions.
- Registration cleans previous `SafeZone_` engine NonPvpZones, clears Lua state
  and boundary caches, optionally merges automatic coverage, registers regions,
  and stores `RegionManager_RegisteredZones` ModData. Keep cleanup before
  generation so disabling coverage removes old generated protection on restart.
- `RegionManager_AutoSafeZones.lua` subtracts enabled PvP rectangles from a
  fixed base-map rectangle and merges fragments. Region coordinates are
  inclusive. Vanilla NonPvpZone upper bounds are exclusive, so registration
  passes `maxX + 1`, `maxY + 1`. Preserve boundary semantics and each version's
  map limits. Generated IDs begin `AutoSafeZone_`; their category is `AUTOSAFE`.
- Explicit `pvpEnabled=false` registers native non-PvP protection. PvP regions
  allow PvP; neutral regions omit that property. Preserve nil in boundary
  payloads instead of converting neutral regions into safe zones.
- Server commands use module `RegionManager`. `RequestAllBoundaries` returns
  `AllZoneBoundaries`. Client `RegionManager_Client.lua` maintains received zone
  data and a spatial lookup, and synchronizes native safe-zone rectangles.
- `RegionManager_ClientTick.lua` checks player coordinates, dispatches entry,
  exit, and periodic callbacks, and owns region notifications. Entries precede
  exits and zone iteration uses unordered tables: enforcement must derive its
  decision from all current zones, not the last event received.
- `RegionManager_PVP.lua` registers a client tick module. With enforcement on,
  it requests safety off in PvP regions, bypassing cooldown when no toggle is
  pending. Explicit safe regions take precedence. With enforcement off or no
  PvP region present it leaves vanilla safety state/timers untouched. Native
  safe-zone damage protection remains independent of this client convenience.
  `RegionManager_PVP_Server.lua` is a legacy command handler; the 42.18 broadcast
  implementation is commented out. Do not assume it provides authoritative
  forced-PvP enforcement.
- Zombie behavior lives in `RegionManager_ZombieModules.lua`,
  `RegionManager_ZombieShared.lua`, server zombie helpers, and client zombie
  modules. Preserve persistent IDs, decision caches, and server validation.
  `Apocalipse_TSY_*` handles sprinter screams and its own sandbox namespace.
- Latest-version `RegionManager_ZombieTraits.lua` provides deterministic
  cognition/sight/hearing profiles from normalized persistent outfit IDs.
  `RegionManager_ZombieTraitsClient.lua` queues OnZombieCreate objects and
  processes one of seven stages per tick, round-robin. Trait rules travel in
  the existing AllZoneBoundaries payload, not per-zombie commands. Completed
  profiles use zombie-local ModData plus a bounded 4096-identity cache; rule
  changes invalidate cached profiles and ownership acquisition queues repair.
  The Lua-only prototype saves/restores sandbox options around DoZombieStats,
  forces door-opening percentage to 0/100, and restores exposed movement
  values. Internal animation/RNG and other stats-initializer effects remain.
  Memory/strength and other zombie traits have no new selection logic here.
  Each queued stage and the applier reject unloaded/detached zombies using
  moving-object membership and live-cell square lookup. Online-ID changes
  invalidate queued incarnations without changing the persistent trait hash.
  Discarded jobs release references; loaded objects can start fresh work.
- `docs/zombie-traits-research.md` records the deterministic trait exploration:
  online-ID lifetime, simulation ownership, sandbox initialization limitations,
  and an application strategy without per-zombie decision commands. Read it
  before replacing the zombie protocol or expanding cognition/memory controls.
- `RegionManager_AdminPanel.lua` and `RegionManager_MapPicker.lua` implement
  administration UI and coordinate selection.

## Sandbox options and translations

Options live in each media tree's `sandbox-options.txt`, outside any module.
For new work, edit only the latest version's options and translations.
New region options use the `RegionManager` namespace and page:

- `AutomaticSafeZones`: boolean, default **true** in 42.18 (**false** in historical
  42.14). Covers the fixed map bounds
  outside enabled PvP regions. Manual safe zones work independently. Restart
  the server after changing coverage to rebuild registered zones.
- `EnforcePVP`: boolean, default **true**. False disables the mod's automatic
  safety toggles and cooldown bypass, leaving vanilla player-controlled safety
  and the configured `SafetyToggleTimer`/`SafetyCooldownTimer` in charge.

Build 42 sandbox labels use `lua/shared/Translate/EN/Sandbox.json` and
`Sandbox_RegionManager_<Option>` / `_tooltip` keys. Existing language folders
and legacy `Sandbox_<LANG>.txt` files are also present. Add new fallback keys
to EN JSON; add other languages when translations are provided. Keep touched
Lua, JSON, and text UTF-8 without BOM. Debug logs use `RegionManager.Log` and
are controlled by `RegionManager.DebugMode`.

## Validation and packaging

Run `npm ci`, `npm test`, `npm run build`, then `npm run test:build`.
Dependencies are pinned in `package-lock.json`. Tests use Fengari to parse all
Lua and execute both versions' coverage and PvP modules with game API stubs;
they also parse JSON and workflow YAML. Package validation compares source
files byte-for-byte, checks Workshop ID, preview and game mod ID, and reruns
the behavioral tests against the compiled package.

`tools/build.mjs` uses pinned PZ Studio with isolated `build/<project title>`
output. `PZ_BUILD_ROOT` overrides the output parent for CI. It preserves the
existing game ID in root `mod.info`. Do not use a global PZ Studio clean that
could target the user's Workshop folder. Do not commit generated builds or
node_modules. The old `watch` script used global output; use explicit builds
unless a safe watch wrapper is added.

For game API changes, verify local decompiled Java at
`Z:\Downloads\ZomboidDecompiler\ZomboidDecompiler\bin\output\source\zombie`.
For safety behavior inspect `characters/Safety.java`, safety packet processing,
and `iso/areas/NonPvpZone.java`. Lua stubs do not verify real multiplayer packet
timing: check in game with two players, vanilla safety timers, all four option
combinations, region entry/exit, overlaps, and a restart after disabling coverage.

## CI and Steam publishing

Follow the same build/artifact/publish/restart flow as `Apocalipse-Music-uploads`:

- `.github/workflows/steam-workshop.yml` runs for PRs, master pushes and manual
  dispatch, calling the local `publish-workshop.yml`. The caller pins shared
  tools from `ApocalipseBr/ApocalipseBRRadio` to the Music Uploads revision.
- Ubuntu builds/test-validates and stages an immutable Workshop artifact using
  the shared `scripts/workshop/stage.py`. It tests the shared publisher tools
  and builds their Docker image. No music/audio dependencies belong here.
- Only master push/dispatch publishes on a self-hosted runner labeled
  `[self-hosted, Linux, X64, pz-workshop]`. It checks out the same tools SHA
  tested by the package job and restores the tested artifact. PRs only validate.
- Publishing uses Steam credentials/session secrets and the shared account
  concurrency group. It updates the existing Workshop item, never creates one.
- Like Music Uploads, confirmed or unconfirmed upload status requests a server
  restart using `PZMANAGER_RESTART_URL` and `PZMANAGER_MOD_UPDATE_TOKEN`.
  Shared `steam_session.py` can refresh remembered session credentials using
  `STEAM_SESSION_GITHUB_TOKEN`; the default secret organization is `ApocalipseBr`.
- Repository/organization secrets: `STEAM_USERNAME`, `STEAM_CONFIG_VDF`,
  optional `STEAM_PASSWORD`, `STEAM_SESSION_GITHUB_TOKEN`, and restart secrets
  above. The self-hosted runner requires Docker, Python 3 and GitHub CLI.
  Never print credential values or commit session data. Local tests/builds do
  not publish; pushing master triggers the configured release workflow.
