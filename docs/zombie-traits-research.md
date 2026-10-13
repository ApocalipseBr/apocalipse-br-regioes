# Deterministic zombie traits: feasibility notes

Investigation of the local mod and decompiled B42 sources, 2026-10-13.
These are design findings, not a gameplay implementation or performance measurement.

Update: a Lua-only cognition/sight/hearing prototype is now implemented in the
latest mod version (42.18). See `docs/zombie-traits-prototype.md` for its actual
queue, identity, caching and sandbox-restoration contract. The investigation
below describes the engine and the mod state before that implementation.

## Conclusion

A pure hash can replace per-zombie trait decision requests and confirmations.
It cannot replace vanilla simulation ownership, guarantee identical AI state on
every observer, or remove the cost of applying properties. Use shared region
configuration and deterministic profiles, then apply them where the engine
actually simulates or consumes those properties.

The best first experiment is cognition with no per-zombie mod commands, applied
once per profile/object change and repaired on ownership acquisition. Keep
server world-interaction and damage handling; the server can derive the same
profile without storing or broadcasting a decision for every zombie.

## Current mod behavior

The older 42.14 client file contains the pending/request/ConfirmZombie pipeline
and the expensive shared ServerSideProperties application path. Its
OnZombieCreate subscription is currently commented out: existing files and
comments alone do not prove that traffic is active.

The 42.18 tree does not contain RegionManager_ZombieClient.lua.
RegionManager_ZombieServer.lua still rolls and stores decisions in global
ModData, but its applyDecisionsToZombie currently calls direct speed methods
and stamps toughness metadata. It does not invoke ServerSideProperties to
apply cognition, sight, hearing, memory, or strength. Its preceding comment
claiming otherwise is stale. Those properties need a new active application
path; replacing a random roll alone would not enable them.

ZombieServerHelper's current LCG is shared mutable state, initially seeded by
os.time unless explicitly seeded. The inspected create path does not seed it
from each zombie ID. It is not a pure identity hash, and its large multiplication
can exceed exact-integer precision in Lua doubles. One roll is compared against
all property chances, correlating traits and allowing conflicting flags.

## Engine evidence

Paths below are relative to the local decompiled zombie source directory.

- characters/IsoZombie.java:3885, DoZombieStats reads cognition, strength,
  memory, sight, hearing, speed and crawl-under-vehicle configuration.
- Cognition=1 sets the zombie field to 1. Cognition=4 uses
  DoorOpeningPercentage to set it to 1 or 0. Values 2/3 do not reset it in this
  method. To deterministically allow/disallow door opening through sandbox
  initialization, Cognition=4 with percentage 100/0 forces the outcome despite
  calling Rand.Next. Merely setting Cognition=3 can leave an old door opener.
- Fixed strength values only write if zombie.strength == -1. Fixed memory
  values similarly require zombie.memory == -1. Re-running DoZombieStats on
  an initialized zombie is insufficient for changing these fixed traits.
- Sight/hearing fixed modes overwrite their fields; random modes use local
  engine RNG. Resolve random choices into concrete categories before applying.
- makeInactive(false), at line 5212 onward, calls DoZombieStats only when
  changing from inactive to active. Cycling inactive also affects movement,
  speed, animation and other stats. Calling DoZombieStats directly avoids
  that cycle but still recalculates speed/crawl chance and uses RNG.
- Direct doSprinter/doFastShambler/doShambler methods avoid the probabilistic
  speed selection in doZombieSpeedInternal. They still randomize speedMod;
  matching speed category does not imply byte-identical movement attributes.
- Some runtime paths also read global lore settings (for example sight,
  hearing and parts of door damage). Per-zombie fields do not universally
  replace global settings. Audit each feature's consumers.
- popman/NetworkZombieManager.java assigns/moves ownership. The simulator's
  becomeLocal restores pathfinding targets; becomeRemote clears ownership.
  In this snapshot these methods do not themselves call makeInactive.
- network/packets/character/ZombiePacket.java carries online ID, outfit ID,
  health, walk type, target, movement/state and related flags. It does not
  carry the five cognition/memory/strength/sight/hearing fields as profile data.
- iso/objects/IsoDoor.java:1187 checks cognition for opening doors; later
  damage code consumes strength. ZombieHitThumpablePacket checks the sending
  client's ownership and invokes the native world-interaction path. Trait
  selection can be stateless while the server still participates in gameplay.

## Controllable properties

| Property | Application route | Main limitation |
|---|---|---|
| Door opening | Cognition + DoorOpeningPercentage + DoZombieStats | Safe off requires 4/0; world interaction still needs native sync |
| Sight / hearing categories | Fixed sandbox mode + DoZombieStats | Global lore reads also exist; random modes are not deterministic |
| Pursuit memory | Cached zombie.memory | Fixed sandbox changes skip initialized fields; needs narrow Java setter for reliable arbitrary changes |
| Strength | Cached zombie.strength | Same initialization limitation; server door damage needs matching value |
| Speed category | doSprinter / doFastShambler / doShambler | Some attributes are locally random and can be recalculated |
| Crawling / walking | setCrawler / setCanWalk / setBecomeCrawler | Changes locomotion/state; verify native packet flags and ownership |
| Crawl under vehicles | setCanCrawlUnderVehicle | DoZombieStats can re-roll it later |
| Fake death / no teeth / uselessness | setFakeDead / setNoTeeth / setUseless | Each needs a separate state/synchronization audit |
| Health / toughness | setHealth plus mod hit handling | Mutable damage state must not be recomputed/reset from the hash |

Cognition should not be treated as three independently exposed intelligence
levels. The inspected initializer primarily controls door opening. A separate
"better navigation" trait needs a concrete behavior and consumer audit.
Global behaviors such as fence lunges/thumping are not automatically per-zombie
properties merely because they appear in ZombieLore.

Public Java fields are not proof that zombie.field=value is writable through
Kahlua. The existing mod notes this bridge limitation; LuaManager exposes field
inspection only in debug mode in the inspected snapshot. Java reflection Field
and Method exposure is also debug-only; it is not a production setter fallback.
A narrow Java helper for these cached fields is the cleanest route if arbitrary
memory/strength changes are required. Runtime interop still needs in-game checks.

## Identity and profile contract

onlineId is a signed short shared by observers of the current network zombie.
network/IsoObjectID.java allocates sequentially, wraps, and skips -1. Objects
reset onlineId to -1 when removed/reset. Thus online ID is suitable for the
current network incarnation, not permanent identity across reloads/restarts.
Negative IDs other than -1 are valid; normalize with id % 65536 and defer -1.
Do not cache forever by online ID: IDs and zombie Java objects can be reused.

PersistentOutfitID is already included in native packets, but outfits can be
changed by this mod and it should not be assumed to be a unique immutable
zombie GUID. The existing AssignedPID metadata is not a zero-traffic solution
unless its availability to new clients is established.

Suggested conceptual selection rule:

    roll = hash(sharedWorldSeed, normalizedOnlineId, propertyKey) % 100
    enabled = roll < percent

Use 0..99, giving exact endpoint behavior for 0% and 100%. Use a separate
property salt for independent traits. For mutually exclusive categories use
one categorical roll with cumulative weights, not several competing booleans.
Specify the hash/version and double-safe integer operations; never seed or
depend on the clients' global RNG or scan order. Include a configuration
revision in the application cache, and decide explicitly whether revisions
should re-roll traits or only change thresholds.

Every participant also needs the same relevant region rules. The same hash
does not fix differences caused by stale configuration, region overlap rules,
or slightly different observed coordinates. Using current zombie position
makes traits dynamic at boundaries. Preserving the original spawn-region
profile requires a shared immutable origin/profile reference; online ID alone
does not encode spawn coordinates.

## Proposed experiment and validation

1. Publish only shared region/configuration data, as the mod already does.
2. Resolve a stateless cognition profile once a valid online ID exists.
3. Apply cognition on the simulation owner; derive the matching server trait
   where server world-interaction code consumes it. Observers follow native
   state packets. Initialize/repair a client's profile before it becomes owner.
4. Cache by live object/incarnation plus profile revision. Skip unchanged
   profiles, bound per-frame application work, and clear recycled objects.
5. For a Lua prototype, save/override/restore only required sandbox options in
   one protected call with restoration on error. Do not cycle makeInactive
   every OnZombieUpdate. Expect remaining engine RNG and recalculation costs.
6. For the efficient version, add a narrow Java API to set/get cognition and
   cached memory/strength/senses without global sandbox mutations or speed
   recalculation. This is an optional follow-up, not yet implemented.

Measure actual application count/time, frame-time percentiles and command
traffic. Test two clients, ownership transfers, joining mid-session, negative
IDs, ID/object reuse, reloads, moving across overlapping regions, config
updates, doors and thump damage. Compare selected profile separately from
observed engine fields; identical hash output alone is insufficient proof.
