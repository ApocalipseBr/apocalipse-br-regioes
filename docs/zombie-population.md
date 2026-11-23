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
| `zombiePopulationMaxDensity` | Maximum living zombies per 10×10 block on `region.z`. Defaults to 1, accepts 0–10, rounds positive fractions up, and disables additions at 0 |
| `zombiePopulationBudget` | Total successful additions allowed for the region ID across unloads and server restarts, capped at 5000. Defaults to the region target |
| `zombiePopulationInterval` | Minimum real seconds between additions in that region; default 30, minimum 1 |
| `zombieRespawn` | True permits repeated top-ups within the remaining budget; otherwise the encounter permanently stops once its target is observed or that many zombies have been added |

The region target is capped at 500. The example has a target of **60** and
permits at most one addition to any block while that block is empty. Blocks
start at the region's minimum X and Y and are clipped at the far edges. Counts
include living real zombies from all sources inside the region on that floor.

No existing example region is automatically opted in. Setting
`RegionManager.Config.Population.Enabled=false` disables this module globally.

## Activation and monitoring

Each tick advances at most one region job, round-robin. Registry discovery
also inspects at most one region entry per tick, using resumable `pairs`
iterators (PZ Kahlua has no global `next`). Loading/reloading regions
replaces the registered table and cancels all old queued work. Jobs use server
players, server chunk lookups and server zombie objects; no client can enable
spawning by claiming a region is loaded.

Initial activation selects a living nearby player within two floors, checks all
overlapping chunks in batches and waits three real seconds. An incremental scan
then walks the region's chunk footprint, checks chunks are loaded and visits
only in-bounds squares on the configured floor. Living `IsoZombie` objects from
`IsoGridSquare:getMovingObjects()` enter a region-owned reference set: a dense
array plus a reference-to-entry lookup. Repeated observations of the same object
do not increase the count. Placement can begin during the initial scan as long
as the count observed so far is below the target. The initial scan keeps its
cursor across placement attempts and player departures, and visits the entire
region while its chunks remain loaded. The global zombie list is never accessed.

Once initialized, bookkeeping continues independently of spawn attempts,
intervals, target completion and lifetime allowance. Maintenance alternates with
placement work, rotating through rolling chunk coverage checks, stale-reference
pruning and a slower rolling tile scan. Tile scans keep their cursor across
spawns and loop continuously; a new spawn does not start a new regional census.
Each tile's initial object-list length limits its scan, so arrivals cannot extend
it indefinitely. Local or unrelated list changes do not abort bookkeeping.

Spawning reads the current dense-array length before placement and again
immediately before the engine spawn call. Successful additions enter that set
immediately. Removal swaps the last entry into the removed slot, updating the
lookup in constant time. `OnZombieDead` queues bounded removals from all tracked
overlapping regions; repeated death callbacks are deduplicated. Background
pruning also removes dead zombies if the callback was missed, zombies leaving
the bounds/floor, detached objects and changed online-ID/outfit incarnations.
Pruning checks the current square against the live cell without calling
`getMovingObjectIndex()`, which performs a linear square-list search in Java.

A missing chunk detected by the watcher, tile scanner or final spawn-location
check clears the entire regional reference set, cancels placement and requires
initialization again. Detection is incremental, not instantaneous: its delay
depends on region size and the number of scheduled regions. Clearing a set is
constant-time; the reverse death-membership index uses weak zombie and region
keys so discarded sets are not retained. Reference sets are runtime-only and
are also discarded on region reload, module disable or server restart.

The player anchor is revalidated during activation and placement. Departure
cancels the active placement attempt, and another player can become the anchor
on a later attempt. Returning preserves the spent spawn allowance and the
normal addition interval.

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
- Scan the candidate's 10×10 block directly before the final player-distance
  check. A full block rejects the candidate even if the region census has not
  reached it yet. If another region places a zombie during this check, repeat it.

Reachability search is limited to 1024 admitted nodes, with at most
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

Global settings live in `RegionManager.Config.Population`. The initial scan and
candidate block scan each visit at most `CensusSquaresPerStep=32` squares and
read at most
`CensusObjectsPerStep=64` moving objects per scheduled step, also bounded by
`ChunkProbesPerStep=8`. A resumed crowded square uses another square visit;
non-zombie objects consume the same object budget. Missing squares inside a
loaded chunk contribute zero. The regional census uses the existing negative
water cache. Initial census and placement alternate when there is placement
work to do, and the census can also use otherwise idle placement turns.
After initialization, `MaintenanceSquaresPerStep=4` and
`MaintenanceObjectsPerStep=16` throttle tile scanning. Other maintenance turns
probe at most eight chunks or prune at most `MembersPerStep=8` references.
Only one region advances per tick. After initialization its selected turns
alternate between maintenance and placement, and maintenance rotates its three
tasks, so a tile-scan turn normally occurs every six selected region turns.
In addition, `DeathMembershipsPerTick=8` bounds queued death processing globally;
the event callback itself only queues a cursor. A backlog can delay removal,
and the reference count can temporarily overstate the living population.
Other phases do at most eight chunk probes, four player reads, four
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

Coverage, scanning, search and placement have no elapsed-time expiry. Work can
span as many ticks as needed under the fixed operation budgets. The three-second
initial settling delay, retry delay, region addition interval and global spawn
spacing remain pacing controls. Search restarts when its player anchor changes
tile, and player-safety scanning restarts when the player-list size changes.
Chunk watching continues during placement; there is no full-region coverage
pass or recount required for every addition. The candidate chunk, square,
walking route and player distances still receive placement checks.

These are approximate multi-tick observations. During the initial scan,
zombies in unvisited blocks may push the true regional count above its target
before the census catches up. Reference membership prevents double counting a
moving object, but arrivals can be missed until a later pass and departed/dead
objects can remain until bounded cleanup.
Local list shrinkage may skip entries until a subsequent scan. Memory grows
with the number of unique regional members; the count is not capped at the
target. Large regions take longer to refresh without increasing per-tick work. A
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
-- searchNodes, expandedNodes, censusTiles, censusElapsedMs, ready,
-- maintenancePhase (1=coverage, 2=prune, 3=tiles); nil for an unmanaged region.
-- observed is the current reference-array length, not a partial-pass count.
```

Enable **Debug logs** in the RegionManager sandbox page (`DebugMode`, default
false) for registration, initial scan start/completion, rolling scan progress, pause reasons and
successful additions through the existing `RegionManager.Log` logging path.
Progress is logged at most once every five seconds within a regional scan pass,
including tracked/target, finished tiles and elapsed milliseconds. Repeated pause
reasons are suppressed until the reason changes or initialization restarts.
Population logs are server-side;
map-form and PvP diagnostics are client-side.
Missing coverage reports `missing chunk`; a changed final walking anchor reports
`walking anchor expired`. There are no scan/coverage timeout pause reasons.
The scanner retains no square or object-list references. The runtime member
array deliberately retains zombie references until removal or invalidation;
scalar diagnostics never expose those objects.

## Validation

`tests/population_spec.cjs` exercises partial/full coverage, reactivation,
departure during work, density/count limits, rolling coverage,
budgets across module reload, one-shot encounters, overlaps, water, occupancy,
missing floors, vehicles, collision, safehouses, other players, and per-tick work
limits. It also exercises pathable door/window/fence edges, north/west stair
ascents and descents, distant-player search at ten ticks/second, partial neighbor
expansion, live geometry revalidation and persistent floor-specific water
exclusions. Local-census cases cover crowded tiles with one-object/one-square
budgets, non-zombie objects, unrelated zombie-list churn, large incremental
scans, progress/completion logs and clipped chunk boundaries. Reference-set
cases verify duplicate observations, movement ahead of the scanner, above-target
counts, death callbacks and missed callbacks, bounded death removal across 12
overlapping regions, departures, detached/reused objects, maintenance throttling,
set reuse across additions and unload/disable cleanup. The global zombie
list stub throws if accessed. It runs through `npm test` and package validation.

These game-API stubs cannot verify actual Kahlua overload dispatch, native
collision geometry, chunk-streaming timing, multiplayer replication or frame
cost. Before production, test the packaged mod on a disposable dedicated save
with two players: enter/leave, split coverage, change floors, open/close doors,
add/remove vehicle obstructions, restart and reload regions, and inspect debug
counts and frame timings. Source evidence and API boundaries are recorded in
`zombie-population-research.md`.
