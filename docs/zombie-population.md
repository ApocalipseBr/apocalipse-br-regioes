# Zombie population additions (42.18)

`media/lua/server/RegionManager_Population.lua` is a separate server module.
It adds zombies toward an explicit target only after the entire region's chunk
footprint is recently verified as loaded. It never requests chunk loading and
does not depend on client messages. Only the latest version was changed.

## Configure a region

Add these properties to a region's `customProperties` in
`RegionManager_Regions.txt` (or the shared config when defining defaults):

```json
{
  "id": "population_example",
  "name": "Population example",
  "x1": 12000,
  "y1": 1000,
  "x2": 12063,
  "y2": 1063,
  "z": 0,
  "enabled": true,
  "categories": ["DEADZONE"],
  "customProperties": {
    "zombiePopulationTarget": 60,
    "zombiePopulationMaxDensity": 1,
    "zombiePopulationBudget": 120,
    "zombiePopulationInterval": 10,
    "zombieRespawn": true
  }
}
```

This is one element of the existing regions file, not a replacement for its
outer structure. Use the existing region reload/admin workflow after editing.
The map picker's Zombie population control section edits count, maximum density,
lifetime allowance, addition interval and replenishment. Blank numeric fields
remove the explicit override and inherit category/module defaults. Count and
allowance must be whole numbers; invalid values prevent submission.

| Property | Meaning/default |
| --- | --- |
| `zombiePopulationTarget` | Positive count enables this module for a region; absent means no population additions |
| `zombiePopulationMaxDensity` | Zombies per 100 tiles, on `region.z`; default 1, permitted range 0–10 |
| `zombiePopulationBudget` | Total successful additions allowed for the region ID across unloads and server restarts; defaults to the effective target, capped at 5000 |
| `zombiePopulationInterval` | Minimum real seconds between additions in that region; default 30, minimum 1 |
| `zombieRespawn` | True permits repeated top-ups within the remaining budget; otherwise the encounter permanently stops once its target is observed or that many zombies have been added |

The target is capped at 500 and at:

```text
floor((maxX - minX + 1) * (maxY - minY + 1) * maxDensity / 100)
```

The example covers 4096 tiles, so its effective target is **40**, despite a
requested count of 60. Counts include living real zombies from all sources on
that region's floor. The density ceiling is a region-wide average over the
rectangle, including water/unusable tiles; it is not a local crowding radius
or a density measurement of traversable terrain. Historical `zombieDensity`
remains untouched because it never had an implemented unit/contract.

No existing example region is automatically opted in. Setting
`RegionManager.Config.Population.Enabled=false` disables this module globally.

## Activation and monitoring

Each tick advances at most one region job, round-robin. Registry discovery
also inspects at most one region entry per tick, using resumable `pairs`
iterators (PZ Kahlua has no global `next`). Loading/reloading regions
replaces the registered table and cancels all old queued work. Jobs use server
players, server chunk lookups and server zombie objects; no client can enable
spawning by claiming a region is loaded.

A cycle selects a living nearby player within two floors, checks all overlapping
chunks in batches, waits three real seconds, checks coverage again, and counts
real zombies in batches. It then samples random coordinates in the region and
performs a bounded directed reachability search from a candidate to the player. Before adding
one zombie it rechecks the entire chunk footprint, revalidates the chosen
walking path in batches, recounts zombies, and checks player distances.

The player anchor is revalidated on every scheduled step. Leaving the area,
disconnecting, death, missing chunks, stale coverage or an expired cycle stops
the work. Another player can become the anchor on a later cycle. Returning to
a region preserves the spent allowance; it does not create a fresh encounter.
There is no fast-forward catch-up of waves after time spent away.

Coverage checks use `getCell():getChunkForGridSquare`, which delegates to
`ServerMap.getChunk` on the dedicated server. A region is never inferred to
be loaded from its center, corners, one player's claimed relevance radius,
or old zombie-list contents.

## Placement rules

- Spawn only at the region's configured z level, on loaded, solid-floor,
  unoccupied, non-water squares; reject stairs and vehicle intersections.
- Reject native safehouses and same-floor `noZombies` region overlaps.
  `noZombies` is an exclusion for additions, not removal of existing zombies.
- Accept the first viable route to the selected nearby player; no shortest-path
  requirement. A greedy best-first heap prioritizes tiles toward the player
  instead of expanding a breadth-first diamond. Search nodes include x/y/z.
- Use the engine's `testPathFindAdjacent(nil,dx,dy,dz)` in both directions.
  Its path matrix permits window edges and `canPath` door/low-fence edges,
  unlike physical collision checks that reject those interactions. A route may
  require opening, smashing or climbing; it does not grant new zombie abilities
  or force the spawned zombie to pursue the player.
- Allow floor changes only between a real north/west top stair and its upper
  landing. Search stays within two floors of the spawn floor, and inside the
  region rectangle extended by 96 tiles on each side. Missing squares, walls,
  vehicle obstructions and arbitrary vertical transitions remain blocked.
  Stair tiles can be traversed but cannot be spawn locations.
- Keep spawn coordinates at least 12 horizontal tiles from living players,
  including players on other floors. This is a proximity check, not a
  guarantee that the spawn is outside every player's line of sight.
- Overlapping controlled regions choose the lexicographically smallest region
  ID as owner of a spawn location. Counts still include all zombies in each
  region. This avoids duplicate additions at shared coordinates.

Reachability search is limited to 1024 admitted nodes and ten seconds, with at most
16 coordinate attempts per cycle. Failure to prove reachability defers spawning.
Movement of the selected player to another tile restarts candidate search rather
than reprioritizing an entire heap. Larger detours may still exceed the bounded
search. Terrain, doors, vehicles and players can change after an incremental
check; the adjacent path matrix is not a full engine navmesh/AI guarantee.

Water observations are permanent negative entries in this world's population
ModData: packed eight-bit row masks per 8x8 chunk/floor. Subsequent candidate,
search and final-validation requests skip a known water coordinate before any
square lookup or water query, including after region reloads and server restarts.
Only observed water is cached; unavailable squares and dynamic obstructions are
never permanently excluded. No square objects are retained. Storage grows with
unique water encountered, with no eviction or full-world scan. If an admin
rebuilds formerly-water terrain, explicitly call the server-side
`RegionManager.Population.ClearWaterCache()` to permit it to be checked again.

## Work budgets and freshness

Global settings live in `RegionManager.Config.Population`. A scheduled step
does at most eight chunk probes, 64 zombie-list reads, four player reads, four
region exclusion checks, or eight path-node expansions/validations, depending
on its phase. Search performs at most 32 neighbor-square probes plus eight active
node-square reads per step (`PathProbesPerStep` and `PathNodesPerStep`). A partial
neighbor expansion resumes next time instead of overshooting that budget.
There are at most eight possible neighbors per node: four same-floor cardinal
neighbors, two oriented top-stair ascents and two possible stair descents.
Heap operations are bounded by the 1024 admitted-node limit. Native
API calls can do their own internal work; these bounds do not guarantee a
particular millisecond duration. No full-world square traversal is performed.

At most one zombie is requested per successful cycle. There is a global
one-second spacing between spawn requests, in addition to the region interval.
Successful result-list sizes are charged to the persisted allowance.

Coverage passes must finish within five seconds; the age of their first probe
determines expiry. A cycle has a 30-second limit. Player-safety scans have a
500ms age limit and restart if the player-list size changes. Many active regions
or players can therefore cause deferral rather than an increased per-tick
budget. For very large regions, smaller independently configured regions are
more useful than increasing these limits without measurement.

These are recent multi-tick observations, not atomic snapshots. The real-zombie
list can move while a census runs; changes to its size abort the census, but
same-size membership changes are not an exact native population census. A
region that becomes over target through vanilla population materialization,
immigration or other mods is left alone and receives no further additions.
No loaded surplus or unloaded native records are deleted. Consequently the
count/density limits govern this module's observed decision to add; they cannot
guarantee an absolute population ceiling against other game systems.

## Persistence and diagnostics

`ModData.getOrCreate("RegionManager_Population")` stores per-region `issued`,
`completed` and `nextAt` (Unix milliseconds). Renaming a region creates a new
identity/allowance; editing its bounds or reloading its existing ID does not
reset spent additions. Raising the budget explicitly allows further additions
when respawn is true. Changing a completed one-shot region to respawn true
also allows remaining budget to be used. Removed IDs retain their small saved
ledger so re-adding an ID does not silently reset its allowance.

Server-side diagnostics:

```lua
local status = RegionManager.Population.GetStatus("population_example")
-- phase, reason, target, issued, budget, observed, cachedWaterTiles,
-- searchNodes, expandedNodes; nil for an unmanaged region.
```

Enable **Debug logs** in the RegionManager sandbox page (`DebugMode`, default
false) for registration, full-coverage activation, pause reasons and successful
additions through the existing `RegionManager.Log` logging path. Repeated pause
reasons are suppressed until the reason changes. Population logs are server-side;
map-form and PvP diagnostics are client-side.
Player departure and cycle timeout have distinct reasons; timeouts name the
phase that expired (for example, `cycle expired during search`).
The state machine retains bounded coordinate/path tables, not zombie objects.

## Validation

`tests/population_spec.cjs` exercises partial/full coverage, reactivation,
departure during work, density/count limits, final recount, final coverage,
budgets across module reload, one-shot encounters, overlaps, water, occupancy,
missing floors, vehicles, collision, safehouses, other players, and per-tick work
limits. It also exercises pathable door/window/fence edges, north/west stair
ascents and descents, distant-player search at ten ticks/second, partial neighbor
expansion, live geometry revalidation and persistent floor-specific water
exclusions. It runs through `npm test` and package validation.

These game-API stubs cannot verify actual Kahlua overload dispatch, native
collision geometry, chunk-streaming timing, multiplayer replication or frame
cost. Before production, test the packaged mod on a disposable dedicated save
with two players: enter/leave, split coverage, change floors, open/close doors,
add/remove vehicle obstructions, restart and reload regions, and inspect debug
counts and frame timings. Source evidence and API boundaries are recorded in
`zombie-population-research.md`.
