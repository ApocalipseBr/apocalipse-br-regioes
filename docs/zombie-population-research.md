# Regional zombie spawning: Lua feasibility

Investigation: 2026-10-20. This is a design note, not an implemented population
module. A later Lua implementation is described in `zombie-population.md`;
the investigation below records its design basis. Mod inspection targets
`Apocalipsebr-regions/42.18`. Engine findings
refer to the local decompiled source, not every Build 42 release. The native
PZPopMan implementation is outside that Java source; native behavior requiring
experimentation is identified below.

## Conclusion

Lua can implement a server-authoritative spawn director without forcing map
loads: choose sites inside regions, activate them when their surroundings are
naturally loaded, count real zombies there, and issue small bounded additions.
Lua can also request hordes through the native population manager without
looking up grid squares first.

Neither capability provides an exact, continuously enforced population cap for
an arbitrary rectangle including unloaded zombies. No supported Lua query for
that total was found in the inspected bridge. Unloaded means unknown, not zero.
The first module should control additions and observed local pressure, rather
than claim to replace vanilla population simulation.

## What the existing mod actually does

- `RegionManager_Config.lua` declares `zombieDensity`, `zombieRespawn`, and
  `noZombies`. DEADZONE supplies density 3 and respawn true; an example region
  supplies density 5. These values have no population enforcement consumer in
  the inspected latest-version Lua tree.
- `RegionManager_Server.lua` merges category defaults with custom properties
  and stores the resolved values in `Server.registeredZones`. It registers a
  generic engine zone with type `Custom`; it does not pass these population
  properties to the native population manager.
- Existing zombie modules change zombie properties; their caches and outfit
  identifiers do not constitute a census of the unloaded world.
- The registered-zone table, region IDs, bounds, and server initialization are
  suitable integration points. No client zombie counting or per-zombie mod
  command exchange is needed to decide server spawns.

## The engine has different representations

1. **Real zombies:** `getCell():getZombieList()` returns the current cell's
   real `IsoZombie` list. On a dedicated server this covers the server's active
   world, not just one player's view. Filter by coordinates and living state.
   A client list is limited to that client's replicated objects.
2. **Unloaded population:** on chunk removal,
   `ZombiePopulationManager.removeChunkFromWorld` sends living zombies to
   `n_addZombie`, including position, state, outfit, native persistent ID and,
   where applicable, path destination. It then removes their real objects.
   Lua cannot enumerate those records through the real-zombie list.
3. **Map population metadata:** `IsoMetaChunk` stores a density/intensity input.
   `getZombieIntensity(false)` and `getUnadjustedZombieIntensity()` concern map
   inputs, not the current number of survivors after kills and migration.
   `getZombieIntensity()` also uses randomness. None is a population census.

The population manager receives loaded-area notifications and periodically
packs real zombie IDs, states and positions into native updates. Native
`n_getAddZombieData` records are turned back into real zombies by Java. A new
real object can therefore be a returning zombie, rather than a newly added
member of the world population.

The inspected source uses **8 x 8 tile chunks and 256 x 256 tile population
cells**. Do not copy B41's 10/300 constants into this implementation without
checking the actual server build. A population cell is also different from
the `IsoCell` object returned by `getCell()`.

## Relevant exposed functions and their limits

| API | Verified Java behavior | Implication |
| --- | --- | --- |
| `getCell():getZombieList()` | Returns real-object list | Can count loaded zombies; cannot count native unloaded records |
| `getCell():getGridSquare(x,y,z)` | Looks up current squares; dedicated server delegates to ServerMap | A missing square is unavailable, not evidence of no zombies; lookup itself does not request a chunk load |
| `addZombiesInOutfit(x,y,z,count,outfit,femaleChance)` | Requires an existing square; returns a list of successfully created zombies | Best initial path for bounded local additions and actual-success accounting |
| `spawnHorde(x1,y1,x2,y2,z,count)` | Random square lookups and real-object creation | Not an unloaded population API despite its name; no success list |
| `createHordeFromTo(sx,sy,tx,ty,count)` | Calls native `n_spawnHorde`, with zero spawn width/height | Native horde request, not an exact local population setter |
| `createHordeInAreaTo(sx,sy,w,h,tx,ty,count)` | Calls the same native method with an area | Does not require Java square lookups, but returns no IDs or accepted count and has no z argument |
| `setMinMaxZombiesPerChunk(min,max)` | Stores manager-wide bounds subsequently sent by `onConfigReloaded` | Global configuration, not regional control; setter is not a demonstrated immediate regional clamp |
| `zpopClearZombies`, `zpopSpawnNow`, `zpopSpawnTimeToZero` | Native debug commands addressed by population-cell coordinates | Too coarse for arbitrary region boundaries; native effects need validation |
| `addVirtualZombie(x,y)` | Empty Java body | Exposed name exists but does nothing in this source |

`createHordeInAreaTo` is worth a separate experiment for remote encounters.
Its Java wrapper alone does not establish native placement distribution,
terrain handling, completion timing, disabled-population behavior, persistence
on immediate shutdown, or migration behavior. It is not an API for populating
an arbitrary floor or keeping a horde within the spawn rectangle.

There is a diagnostic view of population: `MPDebugInfo` requests asynchronous
native cell summaries with current/desired population, while the population
renderer has native visualization and radar support. This does not supply a
normal exposed server Lua function returning counts for arbitrary rectangles.
Cell summaries would also be too coarse to attribute zombies to a small site.

Changing `IsoMetaChunk:setZombieIntensity` is not a verified live population
override: map loading also writes intensity into `LotHeader`, and no examined
setter pushes a regional reconfiguration into existing native population data.
Similarly, temporarily changing global sandbox multipliers is not a regional
solution; `onConfigReloaded` sends global configuration to the native system.

## Proposed first module

Use small **spawn sites inside a region**, rather than requiring its entire
rectangle to load. A site has a spawn footprint and a somewhat larger census
footprint, so zombies walking a short distance away still affect the decision.

1. Build a spatial index from enabled registered regions and configured sites.
   Resolve overlaps explicitly, with exclusion/no-zombie sites taking priority;
   choose one owning policy for additions to avoid duplicate controllers.
2. Select eligible sites with a persisted world seed, stable site IDs and an
   encounter generation. Keep a chosen site and target stable across ticks,
   chunk reloads and server restarts. Randomness should select an encounter,
   not retry indefinitely until every place fills with zombies.
3. Activate a site only when its required chunk footprint is naturally loaded.
   Check bounded chunk probes and actual spawn squares, accounting for absent
   terrain/floors. Missing coverage means defer. Do not iterate every square of
   a large region or use a load-generating API to obtain coverage.
4. Allow a settling period after coverage becomes available. Then periodically
   count real living zombies inside the census footprint, regardless of which
   mod or vanilla path created them. Treat this as an observed local count,
   not proof that native materialization has finished.
5. Add a small batch only if the observation is below the chosen target and
   cooldown, player-distance, placement and budget rules permit it. Spawn on
   valid naturally loaded squares, away from immediate player proximity and
   excluded locations. Use `addZombiesInOutfit` and charge actual successes.
6. After additions, wait and observe again. Stop additions when the target is
   met. Do not delete surplus survivors merely because vanilla migration or
   another spawn path takes the count over the target.
7. When coverage disappears, mark the site unobserved and suspend top-ups.
   Preserve its encounter state and spent budget. Never reset it to empty or
   refund additions on chunk unload.

An illustrative local decision is:

```text
if coverage is incomplete, observation is unsettled, or cooldown is active:
    defer
else:
    request = min(max(0, target - observedReal - reservedLocalAdds),
                  batchLimit, remainingEncounterBudget,
                  remainingRegionBudget, remainingServerBudget)
```

This limits this module's additions; it does not guarantee a hard population
cap against subsequent vanilla materialization, room spawns or immigration.
Reservations protect against duplicate decisions before an addition completes;
they do not turn unknown native population into known population.

For efficiency, identify a bounded set of active sites near online players,
deduplicate overlapping player coverage, and make one scheduled census pass
over the real-zombie list using a spatial index. Avoid a full list scan for
each region or player. If a pass is spread across ticks, its result is an
approximation of moving objects, not an atomic snapshot. Bound square probes,
placement attempts, work per tick and zombies added per interval independently.

## Detecting loaded coverage with bounded work

Follow-up investigation: player relevance is a useful scheduling hint, but
actual chunk presence should decide availability.

`popman/LoadedAreas.set()` builds player rectangles from chunk coordinates and
`IsoPlayer.onlineChunkGridWidth`, and also includes connection `connectArea`
rectangles. Separately it reports server-cell areas. `ServerMap` has queued
loading, recalculation and unloading stages, so a player relevance rectangle
is not an acknowledgement that every requested chunk has finished loading.
The width is a public Java field in the inspected player class, with no
matching getter found; do not assume ordinary Lua field access works or
hardcode a universal relevance radius.

There is a directly useful exposed path:

```lua
-- cx/cy are chunk coordinates; this source uses 8 tiles per chunk.
local function chunkPresent(cell, cx, cy)
    return cell:getChunkForGridSquare(cx * 8, cy * 8, 0) ~= nil
end
```

On the dedicated server `IsoCell.getChunkForGridSquare` delegates to
`ServerMap.instance.getChunk`. That lookup returns a chunk only when its
server cell exists and `isLoaded` is true; it does not request loading. The z
argument does not affect this server chunk lookup. Validate the actual spawn
square and floor separately. Avoid `IsoCell:getChunk` for this task: its
implementation searches local player chunk maps rather than taking the same
explicit dedicated-server branch.

This matches vanilla `BuildingDef.isFullyStreamedIn`: it checks for non-null
chunks across the building footprint. It does not establish that all native
population materialization or later room spawns have completed.

For inclusive region bounds, calculate the chunk rectangle once:

```text
cxMin = floor(minX / 8); cxMax = floor(maxX / 8)
cyMin = floor(minY / 8); cyMax = floor(maxY / 8)
requiredChunks = (cxMax - cxMin + 1) * (cyMax - cyMin + 1)
```

Use a resumable cursor over those chunk coordinates, not an allocated table
of every square. A global scheduler can grant, for example, eight chunk probes
per tick across all candidate regions. A single region covering exactly
64 x 64 tiles on chunk boundaries needs 64 probes: eight ticks at that budget
if it is the only job. This is an example budget, not a measured recommendation.
Stop early on a missing chunk and put the job into retry backoff. Regions
sharing chunks can reuse a short-lived probe cache.

Keep only scalar job state: bounds/config generation, cursor, pass start time,
last complete pass, settling deadline and status. Check each coordinate once
per pass; a running success count must not count repeated probes twice.
Continue periodic verification after activation. Never leave a permanent
`fullyLoaded=true` based on an old pass.

Chunk-boundary player movement, disconnects, teleports, relevance-width changes
where observable, and region edits should invalidate affected readiness or
prioritize verification. Do not invalidate for every sub-tile player movement.
Without reliable width access, player proximity can prioritize jobs while
actual chunk probes remain the only positive coverage evidence. Distant jobs
should retain a low-frequency bounded retry path if eligibility is heuristic.

An incremental pass is not an atomic full-region check: its first chunk might
unload before its last chunk is tested. Require a bounded maximum pass age;
if it cannot finish inside that window, defer or split into smaller sites.
A second successful pass plus a settling interval gives conservative readiness,
not mathematical proof. Recheck the target chunk and bounded local spawn
footprint immediately before a small spawn batch, and stop on any failed
check. An instantaneous full-region guarantee requires synchronous checking
or reliable engine lifecycle notifications/stronger bridge support.

For Lua alone, define readiness honestly as "all required chunks recently
verified, no known invalidation, settling elapsed", rather than claiming an
atomic snapshot. Keep the native-population uncertainty described above even
when this loaded-coverage condition is met. If a large region is rarely fully
covered by players, independent sites are preferable to one all-region gate.

## Persisted state and population accounting

Store module state in its own server global ModData key, keyed by stable
region/site IDs: schema version, encounter generation, chosen target, seed,
issued additions, remaining budget, next eligible world-age time and relevant
configuration revision. Do not persist Java object references. Define explicit
behavior for region deletion, edited bounds and restart recovery.

Separate three quantities: **requested additions**, **confirmed real additions**,
and **currently observed zombies**. None is the total surviving population of
an unloaded region. In particular:

- `spawned - killed` ignores original residents, migration, other mods, and
  uncertain identity/death delivery. It is not a regional census.
- A zombie disappearing from the list may have unloaded or left the area. It
  does not justify a replacement.
- Arbitrary zombie-local ModData is not transported in the examined native
  virtualization record. Do not assume a custom spawn tag survives unload.
- The source has a native `persistentId` distinct from the persistent outfit
  ID used by existing mod helpers. A public Java field is not proof of usable
  Lua field access. Stable identity access and lifecycle must be tested before
  building a cross-unload membership ledger.
- `OnZombieCreate` fires before insertion into the zombie list, server online
  ID assignment and native ID registration in `createRealZombieAlways`.
  Queue observation until initialization is complete; the event can also fire
  for a re-materialized zombie and is not a world-birth counter.
- `OnZombieDead` exists in Java death paths. Dedicated-server delivery,
  duplicate prevention, and attribution require testing before using kills
  to replenish a budget. A periodic loaded census remains useful regardless.

Start with a finite persisted budget per encounter. Replenishment must be an
explicit gameplay policy with a region/server rate limit, not an automatic
refund on unload, elapsed time or disappearance. Repeated timed waves can
accumulate survivors; even a rate limit does not establish a lifetime cap.
Native remote horde requests have the additional problem that Lua has no
success acknowledgement: conservatively charge the request and do not retry
just because no real objects are visible.

`zombieRespawn=false` can initially mean only "this module does not replenish
this site's encounter". It cannot honestly mean "vanilla never respawns here".
Likewise `noZombies` would need separate active enforcement and would not erase
unloaded native records. `zombieDensity=3` cannot yet promise three times the
vanilla surviving population: define an explicit count or density unit first.

## What needs a deeper bridge

Exact arbitrary-area native counts, per-region vanilla respawn overrides, and
selective removal of unloaded zombies would require additional engine/native
access beyond the inspected Lua interface. A Java bridge could expose existing
cell summaries, but exact rectangle queries may require native support too.
Do not promise that a Java patch alone can implement a native query that does
not already exist.

## Small in-game validation before implementation

Use a disposable dedicated-server save and the actual deployed build:

1. Observe a site, unload it normally, and return. Verify the Lua list loses
   real objects while the population survives. Log count, coverage and state.
2. Spawn a small real batch; inspect returned success count, two-client
   replication, subsequent unload/reload, and restart. Verify budget persists.
3. Separately request one small native horde in an unloaded known-valid area.
   Observe arrival, target movement, eventual materialization and persistence.
   Do not run an automatic retry loop during this experiment.
4. Exercise two players, overlapping sites, partial coverage, kills, migration,
   room discovery, other spawn sources and configuration changes. Verify a
   missing square never becomes a zero-population observation.
5. Test disabled zombies and vanilla respawn settings independently. Confirm
   exclusions, safehouses and any player-visibility checks with real players.
6. Measure scheduler time, list traversal, square probes, spawn attempts and
   actual additions. Select work budgets from those measurements.

## Source map

Paths below are relative to
`Z:/Downloads/ZomboidDecompiler/ZomboidDecompiler/bin/output/source/zombie`:

- `popman/ZombiePopulationManager.java`: constants; native declarations;
  `onConfigReloaded`, `removeChunkFromWorld`, `virtualizeZombie`,
  `createHordeInAreaTo`, `packRealZombies`, `updateMain`, `addZombieStanding`,
  `addZombieMoving`, `updateLoadedAreas`, and debug command wrappers.
- `Lua/LuaManager.java`: class exposure list; `setMinMaxZombiesPerChunk`,
  horde globals, `addZombiesInOutfit`, zpop globals, empty `addVirtualZombie`.
- `VirtualZombieManager.java`: `createRealZombieAlways` event ordering,
  native registration, `getZombieCountForRoom`, `roomSpotted`.
- `popman/MPDebugInfo.java`: native summary request pipeline, `MPCell`, render.
- `popman/ZombiePopulationRenderer.java`: native rendering and cell display.
- `iso/IsoCell.java`: `getZombieList` and server square lookup delegation.
- `iso/IsoMetaChunk.java`, `iso/IsoMetaGrid.java`, `iso/LotHeader.java`:
  intensity inputs and map loading.
- `characters/IsoZombie.java`: `onKilled`, `removeFromWorld`, reusable-object
  cleanup and persistent native ID.

Installed vanilla Lua also uses `createHordeFromTo` in
`media/lua/client/LastStand/Challenge1.lua` and sets manager-wide chunk bounds
before world initialization in `LastStandSetup.lua`.

The official historical population explanation describes the intended distinction
between current and desired cell population, but is not Build 42 API evidence:
https://projectzomboid.com/blog/news/2015/05/bring-out-your-zed/
The conclusions above use local Java behavior rather than assuming that the
historical implementation or online Javadocs match this server.

## Directed reachability and permanent water exclusions

The later population implementation uses the existing Lua-exposed square APIs
instead of submitting requests to the engine's asynchronous mover pathfinder:

- `iso/IsoGridSquare.java`, `testPathFindAdjacent(IsoMovingObject,int,int,int)`:
  the mover argument is unused in this overload's implementation. It checks
  cached `pathMatrix` bits (or `CalculateCollide` with `bPathfind=true` in slow
  mode). Its boolean means blocked, not successful. Top stairs explicitly reject
  continuing forward at the same z level.
- `CalculateCollide`: pathfinding permits window edges and clears cardinal
  collision for `canPathN`/`canPathW` flags. Stair logic permits oriented
  top-stair/upper-landing transitions. This is adjacency-level reachability,
  not the complete zombie navigation/interaction controller. The Lua search
  explicitly restricts floor changes to these top-stair connections and checks
  both edge directions, loaded squares, terrain and vehicle obstruction.
- `HasStairTopNorth`/`HasStairTopWest` identify the top stair. The upper landing
  is one square north/west and one level above; reverse edges permit descent.
- `isWaterSquare` checks the floor object's `FloorMaterial == Water`. It does
  not classify every absent square as water. Positive water observations can
  therefore be packed into persistent chunk/floor row masks without retaining
  Java objects. This deliberately treats observed water as permanently excluded;
  terrain edits require the explicit `Population.ClearWaterCache()` escape hatch.

The Lua greedy best-first search accepts any route, uses x/y/z identities and
a bounded heap, and resumes neighbor expansion at the per-tick probe limit.
It never submits an engine mover request, constructs a dummy zombie, or modifies
a real player's navigation. Native APIs may perform internal work beyond the
bounded number of Lua calls. Real multiplayer staircase and interaction behavior
still needs in-game validation; API stubs establish the module's scheduling and
route-selection contract, not the entire engine navigation behavior.
