# Cognition, sight and hearing prototype (42.18)

This is the user-selected Lua-only prototype. It adds no new speed, memory,
strength, crawling, fake-death, vehicle-crawling or no-teeth trait selection.
Server-controlled speed uses its existing path.

## Shared rules and deterministic decisions

The existing `AllZoneBoundaries` payload now includes `zombieTraits` with the
server's merged category/custom-property chances. No new per-zombie command,
confirmation request or server-side decision record is needed for these three
client traits. Existing server zombie data/commands for other features remain.

Supported fields:

- Cognition: `navigationChance` controls door-opening eligibility. Successful
  rolls force `ZombieLore.Cognition=4` and `DoorOpeningPercentage=100`; failed
  rolls force mode 4 and percentage 0. This avoids the engine's failure to clear
  door-opening cognition when switching to modes 2/3.
- Sight: `hawkVisionChance`, `normalVisionChance`, `poorVisionChance` /
  `badVisionChance`, and `randomVisionChance`.
- Hearing: `pinpointHearingChance` / `goodHearingChance`,
  `normalHearingChance`, `poorHearingChance` / `badHearingChance`, and
  `randomHearingChance`.

Overlapping regions contribute the maximum chance per property. Senses retain
the existing priority: enhanced, normal, poor, then random. These percentages
are overlapping threshold chances, not additive categorical weights. Each
sense produces one concrete category. Random categories and vanilla random
defaults are resolved locally through a separately salted deterministic hash.
Regions with no supported numeric chances cause no application call.

The hash uses 0..99 and `roll < chance`, with separate cognition/sight/hearing
salts. It uses double-safe arithmetic and no global RNG or scan-order seed.

Identity uses the existing `Apocalipse_TSY_AssignedPID` when present, otherwise
PersistentOutfitID plus sex. Outfit-based IDs are normalized for signedness and
the hat-loss bit. Online ID is not part of the roll, so an online-ID reassignment
does not reroll a stable outfit identity. Unassigned/zero outfits wait in queue.
The existing outfit identity is not a unique immutable zombie GUID: repeated
outfit variants can share rolls, and outfit replacement without an available
AssignedPID can change identity. This prototype does not add ID synchronization.

## Queue and application

OnZombieCreate queues the object; duplicate queue requests coalesce. Each tick
processes one stage from the front and requeues unfinished jobs at the back:

1. Resolve identity, baseline options and rule revision; snapshot position.
2. Reuse a completed profile or aggregate region rules at that position.
3. Compute cognition.
4. Compute sight.
5. Compute hearing.
6. Apply the combined profile once.
7. Complete/cache the profile.

For 100 ready, controlled zombies, this is 700 queue ticks and at most one stats
call per tick. Unknown identities/configuration can defer completion; dead or
unloaded objects and regions without controls finish early. This is work pacing,
not a measured guarantee of frame time or a synchronized wall-clock cadence.

The applier caches native ConfigOption references and saves their current
values. All temporary setting changes, the single DoZombieStats call and
restoration occur inside the same tick. Options restore even if the call fails.
It never leaves an override active between queue stages or uses makeInactive.

DoZombieStats still calls other native initialization logic. The prototype
restores exposed walk type, derived speed category, speed modifier and
crawl-under-vehicle eligibility afterward. It cannot fully undo internal
animation changes, RNG consumption or every other initializer side effect.
Native random memory can also reroll. A narrow Java setter is required to avoid
these side effects completely. The user explicitly chose the Lua-only route.

## Persistence and repairs

Completed profiles are stamped in zombie-local
`Apocalipse_TSY_ClientTraits` ModData. A bounded FIFO cache retains the last
4096 identities for reuse when a new local object appears after unload, even
if it has since moved. Cached profiles are reused only when the normalized
identity, profile version and relevant region-rule signature match. Available
matching zombie ModData is also reused. Rule changes invalidate the local cache.

These client records are not advertised as server-persisted or automatically
replicated. New clients without a record calculate from the region position
they first process. Thus moving zombies near region boundaries can still get
different initial profiles across observers. Guaranteeing the original spawn
region for late joiners would require a shared origin/profile reference.
After cache eviction/restart without retained metadata, rolls remain stable
for a stable identity, but region-dependent final profiles are recomputed.

OnZombieUpdate performs lightweight discovery, configuration-revision and
ownership checks. It queues a repair when this client acquires ownership.
It does not continuously mutate settings for every visible zombie or verify
every field every frame. Native later recalculation can overwrite traits until
a repair/reload occurs. Existing server world-interaction mismatches are outside
this prototype, as requested.

## Why region sandbox cadence is insufficient

Sandbox options are global to a game process, not attached to a region. One
client can simultaneously observe zombies from several regions. A single
global value cannot represent their different settings before all spawns.
Clients also construct replicas at different times and consume different RNG
sequences. The same setting and nominal cadence therefore do not guarantee
the same traits for one zombie.

If time-varying region rules are wanted later, send a seed, shared world-time
epoch, interval and configuration revision once through region configuration.
Clients can calculate future intervals locally; asking the server for each
next X minutes is unnecessary. Still select per-zombie profiles deterministically
and apply them locally. Using a shared spawn epoch requires that epoch to be
available to late joiners; client-local replica creation time is insufficient.

## Validation

`npm test` executes latest-version hash/identity/queue tests, in addition to
existing region checks. Tests cover endpoints, alias handling, overlap rules,
hat normalization, unknown identities, all 100 percentiles, queue deduplication,
100 zombies over 700 ticks, reload-cache reuse, ownership repair, failed-call
restoration, dead objects and configuration changes. `npm run test:build`
repeats behavioral tests against the compiled package.

In-game validation remains required: two clients observing the same zombies,
ownership transfer, streaming unload/reload, hat loss and outfit changes, rule
updates, doors, sense behavior, mixed regions, late joins and frame-time
measurements. Compare server speed/animation before and after initialization.

## Streaming and unload cancellation

Every queue stage validates that the zombie is alive, has a current square,
remains attached to its square's moving-object list, and that the square is
still the live cell's grid square. This rejects stale square pointers after
chunk removal. The applier repeats the check before touching sandbox options
or zombie fields, including when called directly.

Jobs bind to the first valid online ID as an incarnation guard; that ID does
not influence trait hashing. An ID change or a newer OnZombieCreate job
invalidates the old job. Discarding releases its zombie reference and partial
profile. OnZombieUpdate also cancels detached jobs and does not requeue them
until the object is loaded again. Reloaded objects start fresh work and can
reuse an existing completed persistent-identity profile.

No later stage reads/writes zombie ModData or applies traits after the object
is detected as unloaded. If unloading happens after stage 6 has already
applied traits while the zombie was loaded, stage 7 is discarded without
additional writes. Tests cover unload before all seven stages, stale square
references, detached membership, direct application rejection, ID changes,
superseded jobs, and successful application after reload.
