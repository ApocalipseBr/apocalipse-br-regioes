# ApocalipseBR - Regiões

> **Mod ID:** `ApocalipseBR_Regioes`  
> **Author:** Hypothetic  
> **Target version:** Build 42 (≥ 42.14.0)  
> **Build system:** pzstudio  

Custom region management for Project Zomboid multiplayer servers. Divides the game map into rectangular zones with independent PVP rules, zombie property overrides (speed, vision, hearing, toughness, memory, navigation, armor), and a sprinter scream system (originally by SIMBAproduz / "theySEE YOU").

Latest-version regional zombie population additions are documented in
[Zombie population control](docs/zombie-population.md): explicit count targets
clamped by a density ceiling, incremental server coverage/counting/walking
checks, and persisted spawn budgets. Regions opt in with
`zombiePopulationTarget` in `customProperties`.

---

## Table of Contents

- [ApocalipseBR - Regiões](#apocalipsebr---regiões)
  - [Table of Contents](#table-of-contents)
  - [1. Project Structure](#1-project-structure)
  - [2. Region System Architecture](#2-region-system-architecture)
    - [2.1 Region Definition](#21-region-definition)
    - [2.2 Categories \& Property Merging](#22-categories--property-merging)
    - [2.3 Auto-Safe Zone Generation](#23-auto-safe-zone-generation)
    - [2.4 External JSON Region File](#24-external-json-region-file)
  - [3. Server-Side Zone Registration](#3-server-side-zone-registration)
  - [4. Client-Side Tick Dispatcher](#4-client-side-tick-dispatcher)
  - [5. PVP System](#5-pvp-system)
    - [5.1 Safety Toggle Flow](#51-safety-toggle-flow)
    - [5.2 Native Safe-Zone Protection](#52-native-safe-zone-protection)
    - [5.3 Synchronization](#53-synchronization)
  - [6. Zombie Property System](#6-zombie-property-system)
    - [6.1 Spawn Hook Pattern (OnZombieCreate → ConfirmZombie)](#61-spawn-hook-pattern-onzombiecreate--confirmzombie)
    - [6.2 Server-Side Decision Pipeline](#62-server-side-decision-pipeline)
    - [6.3 Protocol v2 Bit-Encoded Payload](#63-protocol-v2-bit-encoded-payload)
    - [6.4 Client-Side Property Application](#64-client-side-property-application)
    - [6.5 Speed Revalidation (Ownership Transfer Fix)](#65-speed-revalidation-ownership-transfer-fix)
    - [6.6 Tough Zombie Hit System](#66-tough-zombie-hit-system)
  - [7. Zombie Module System (Boss Zombies)](#7-zombie-module-system-boss-zombies)
    - [7.1 Module Registration API](#71-module-registration-api)
    - [7.2 Client-Side Module Engine](#72-client-side-module-engine)
  - [8. Sprinter Scream System (Apocalipse\_TSY)](#8-sprinter-scream-system-apocalipse_tsy)
    - [8.1 Scream Types](#81-scream-types)
    - [8.2 Cluster Anti-Spam](#82-cluster-anti-spam)
    - [8.3 Horde Alert Mechanic](#83-horde-alert-mechanic)
    - [8.4 Sound Architecture](#84-sound-architecture)
  - [9. AnimSets (Sprinter Animations)](#9-animsets-sprinter-animations)
  - [10. Sandbox Options](#10-sandbox-options)
  - [11. File Reference](#11-file-reference)
    - [Shared (client + server)](#shared-client--server)
    - [Server](#server)
    - [Client](#client)
    - [Data / Config](#data--config)

---

## 1. Project Structure

```
apocalipse-br-regioes/           ← pzstudio project root
├── project.json                 ← pzstudio config (workshop metadata)
├── package.json                 ← npm scripts (clean, build, test, test:build, update)
├── Apocalipsebr-regions/
│   ├── common/                  ← Mandatory common folder (loads first)
│   │   └── media/
│   │       ├── sandbox-options.txt
│   │       ├── scripts/Apocalipse_TSY_Sounds.txt
│   │       ├── sound/           ← ABMIS_01..62.mp3 scream voice files
│   │       └── lua/
│   │           ├── client/Apocalipse_TSY_Main.lua
│   │           └── shared/Translate/<LANG>/
│   └── 42.14/                   ← Version-specific folder (overrides common)
│       ├── mod.info
│       └── media/
│           ├── sandbox-options.txt
│           ├── AnimSets/zombie/       ← Custom sprinter animation sets
│           ├── scripts/Apocalipse_TSY_Sounds.txt
│           ├── sound/
│           └── lua/
│               ├── client/
│               ├── server/
│               └── shared/
```

The `common/` folder loads first; then the closest version folder `≤` current game version overlays on top.

---

## 2. Region System Architecture

### 2.1 Region Definition

Every region is a **2D axis-aligned rectangle** defined by two opposite corner coordinates (`x1,y1` → `x2,y2`) at a given Z level. Regions are defined in `RegionManager_Config.lua` under `RegionManager.Config.Regions` as an array of `RegionDefinition` tables:

```lua
{
    id          = "lousville_test_area",   -- Unique string identifier
    name        = "Lousville test area",   -- Human-readable name
    x1 = 12590, y1 = 810,                 -- First corner (world coords)
    x2 = 12609, y2 = 904,                 -- Opposite corner
    z  = 0,
    enabled     = true,
    categories  = {"PVP", "SPRINTERS"},    -- Category keys (see §2.2)
    customProperties = {                   -- Overrides category defaults
        zombieSpeed    = 3,
        zombieDensity  = 5.0,
        pvpEnabled     = true,
        sprinterChance = 100,
        message        = "Hostile territory!"
    }
}
```

At registration time, coordinates are normalized to `min/max` bounds for fast AABB collision detection.

### 2.2 Categories & Property Merging

Each region references one or more **category keys**. Categories provide default `ZoneProperties` values:

| Category | Default Properties |
|---|---|
| `PVP` | `pvpEnabled=true`, red color, announce on enter/exit |
| `SPRINTERS` | Orange color, announce on enter/exit |
| `SHAMBLERS` | Orange color, announce on enter/exit |
| `SAFEZONE` | `pvpEnabled=false`, `noZombies=true`, green color |
| `LOOTBONUS` | `lootModifier=1.5`, blue color |
| `DEADZONE` | `zombieDensity=3.0`, `zombieRespawn=true`, purple color |
| `CUSTOM` | Grey color, no announcements |
| `AUTOSAFE` | Auto-generated safe zone, `pvpEnabled=false`, cyan color |

**Merge order (in `getMergedProperties()`):**
1. Iterate each category in order and apply its defaults (first writer wins for duplicate keys)
2. Apply `customProperties` on top (always wins - highest priority)

The resulting flat `ZoneProperties` table is stored in `RegisteredZoneData.properties`.

### 2.3 Auto-Safe Zone Generation

The `RegionManager_AutoSafeZones` module optionally covers the configured map bounds with non-PvP zones. Enable `RegionManager.AutomaticSafeZones` to activate this behavior; it is **disabled by default**. On server startup with coverage enabled:

1. Start with the fixed map rectangle: `(-1780,-2272)-(20455,16541)` for 42.14, or `(-1780,-2272)-(21143,18513)` for 42.18
2. Identify all PVP-enabled regions from the config
3. **Subtract** every PVP rectangle from the safe zone using a rectangle subtraction algorithm, producing up to 4 fragments per subtraction
4. **Merge** adjacent fragments back together (only if the merged result doesn't overlap any PVP zone)
5. Output auto-generated `AUTOSAFE` regions that are combined with the config-defined regions

When enabled, the covered map bounds contain either a PvP region or an automatic non-PvP region. When disabled, only configured regions are registered, so neutral areas retain vanilla rules. Manually configured safe zones remain protected in either mode. Restart the server after changing coverage; registration removes old generated zones before rebuilding.

### 2.4 External JSON Region File

Regions are persisted to `RegionManager_Regions.txt` in the Zomboid directory via the game's `getFileWriter/getFileReader` API. On first boot the file is created from `RegionManager.Config.Regions`. On subsequent boots the file is loaded instead, allowing external tools or admin APIs to modify regions without touching Lua source code.

Format:
```json
{
    "version": "1.0",
    "lastUpdated": "2026-04-10 12:00:00",
    "regions": [ /* RegionDefinition[] */ ]
}
```

---

## 3. Server-Side Zone Registration

**File:** `RegionManager_Server.lua`  
**Event:** `Events.OnLoadMapZones`

1. **Cleanup** - Remove all previous `SafeZone_*` NonPvpZones and clear the Lua-side `registeredZones` table
2. **Load** - Read regions from the external JSON file (or create it from defaults)
3. **Auto-Safe** - Call `AutoSafeZones.mergeWithConfigured()` to add generated safe zones
4. **Register** - For each enabled region:
   - Compute merged properties
   - Normalize coordinates to `min/max` bounds
   - Call `world:registerZone(id, "Custom", centerX, centerY, z, width, height)`
   - Store in `RegionManager.Server.registeredZones[id]` with the region definition, merged properties, bounds, and engine zone handle
5. **Persist** - Save to ModData under key `RegionManager_RegisteredZones`

**Client commands handled:**
| Command | Purpose |
|---|---|
| `RequestAllBoundaries` | Send all zone boundary + property data to the requesting client |
| `RequestZoneInfo` | Find which zones contain a given (x,y) point |
| `ExportConfig` | Admin-only: export config to JSON file |

---

## 4. Client-Side Tick Dispatcher

**File:** `RegionManager_ClientTick.lua`

A central tick loop (every 6 ticks ≈ 100ms at 60 FPS) that:

1. **Checks player position** against all known zone boundaries (received from server via `AllZoneBoundaries`)
2. **Detects zone transitions** by comparing current zones to previous zones
3. **Fires callbacks** on registered modules:
   - `onZoneEntered(player, zoneId, zoneData)` - player just entered a zone
   - `onZoneExited(player, zoneId, zoneData)` - player just left a zone
   - `onTick(player, currentZones)` - called every tick interval

**Module registration API:**
```lua
RegionManager.ClientTick.registerModule({
    name = "MyModule",
    onZoneEntered = function(player, zoneId, zoneData) end,
    onZoneExited  = function(player, zoneId, zoneData) end,
    onTick        = function(player, currentZones) end,
})
```

Currently registered tick modules:
- **PVP** - Safety state enforcement (see §5)
- **Apocalipse_TSY_SpawnProcessor** - Drains the pending zombie queue (see §6.1)
- **Apocalipse_TSY_SpeedRevalidation** - Round-robin speed drift correction (see §6.5)

On player spawn (`OnCreatePlayer`), zone state is cleared and boundaries are re-requested from the server.

---

## 5. PVP System

### 5.1 Safety Toggle Flow

**File:** `RegionManager_PVP.lua` (client).

Latest implementation (`42.18` folder): each PvP region uses `customProperties.forcedPvP`. Missing or `true` forces vanilla safety off, clearing the cooldown when no toggle is pending. `false` makes PvP optional and leaves player safety/timers untouched. This per-region rule supersedes the legacy `RegionManager.EnforcePVP` sandbox setting, regardless of its value. The map builder provides an inherit/forced/optional selector. Category defaults can also define this property.

Explicit safe regions still take precedence over overlapping PvP regions. Any forced PvP region imposes enforcement even when an optional PvP region overlaps it; neutral regions do not impose a safety state. Leaving all forced regions releases enforcement without automatically turning safety back on. Historical `42.14` retains the previous global `EnforcePVP` behavior. See [per-region policy](docs/forced-pvp.md).

### 5.2 Native Safe-Zone Protection

Configured safe regions and optional automatic safe regions register native `NonPvpZone` rectangles on the server. Boundary payloads synchronize these rectangles on clients. This protection works independently of the enforcement option; disabling enforcement does not permit damage inside native non-PvP zones.

### 5.3 Synchronization

Safety changes use vanilla `Safety:toggleSafety()` and its native networking. The PvP module no longer tracks or punishes toggle attempts. The legacy `RegionManager_PVP_Server.lua` custom broadcast handler remains in the version trees; its 42.18 broadcast code is commented out.

---

## 6. Zombie Property System

This is the core of the mod. It overrides sandbox zombie settings **per-zombie** based on the region where the zombie spawned.

### 6.1 Spawn Hook Pattern (OnZombieCreate → ConfirmZombie)

**Problem:** `Events.OnZombieCreate` fires on the client **before** the server assigns an `onlineID` to the zombie.

**Solution - Deferred Processing:**

```
Client                                 Server
  │                                      │
  │ OnZombieCreate fires                 │
  │ ├─ zombie has onlineID = -1          │
  │ ├─ Queue zombie in PendingZombies    │
  │                                      │
  │ ... next tick(s) ...                 │
  │                                      │
  │ ProcessPending (tick module)          │
  │ ├─ Check onlineID >= 0?             │
  │ │   └─ YES: build proposal           │
  │ │       {zombieID, persistentID,     │
  │ │        x, y, outfitName}           │
  │ ├─ Mark zombie as Processed          │
  │ └─ Batch all proposals into          │
  │    "RequestZombieInfo" command ──────►│
  │                                      │ Resolve decisions:
  │                                      │ ├─ Check ModData cache
  │                                      │ ├─ Check ZombieModules (outfit match)
  │                                      │ └─ Fall back: FindRegionsAt(x,y)
  │                                      │    → AggregateChances()
  │                                      │    → RollDecisions()
  │                                      │ Store in ModData
  │◄──── "ConfirmZombie" ───────────────│
  │                                      │
  │ Decode bit-encoded payload           │
  │ Find zombie by onlineID              │
  │ Apply ServerSideProperties()         │
  │ Cache payload in zombie modData      │
  │ Add to SpeedTracker if sprinter/     │
  │   shambler                           │
```

**Key design decisions:**
- **PendingZombies queue** - Only newly-spawned zombies are queued, not the entire cell list. Typical queue size is 0-20.
- **Batch requests** - All pending zombies processed in one tick are sent as a single `RequestZombieInfo` command with an array of proposals.
- **PersistentID** - Built from `getPersistentOutfitID()` + `isFemale()`. Stable across respawns and ownership transfers.
- **Position mismatch guard** - Server discards cached decisions if the zombie's position differs by >300 tiles (recycled zombie detection).

### 6.2 Server-Side Decision Pipeline

**File:** `RegionManager_ZombieServerHelper.lua`

```
Zombie Position (x, y)
        │
        ▼
FindRegionsAt(x, y)           ← O(n) bounds check across registered zones
        │
        ▼
AggregateChances(regions)     ← Take MAX chance for each property across
        │                        all overlapping zones
        ▼
RollDecisions(chances, x, y)  ← Single deterministic random [0,100)
        │                        Each chance > roll → property enabled
        ▼
decisions table               ← 28 booleans + position + maxHits + armor values
```

**Overlapping zones use MAX aggregation** - if zone A has `sprinterChance=30` and zone B has `sprinterChance=80`, the effective chance is 80%.

**Deterministic RNG** - Uses a Linear Congruential Generator (LCG) with `seed * 1103515245 + 12345 mod 2^31`. The seed is set per-zombie from time-based values.

**Configurable per-region zombie properties (all as 0-100 percentage chances):**

| Property | Key in `customProperties` | Effect |
|---|---|---|
| Speed: Sprinter | `sprinterChance` | Converts to sprinter (speed=1) |
| Speed: Shambler | `shamblerChance` | Converts to shambler (speed=3) |
| Vision: Eagle | `hawkVisionChance` | Eagle eye sight |
| Vision: Bad | `badVisionChance` | Poor sight |
| Vision: Normal | `normalVisionChance` | Normal sight |
| Vision: Poor | `poorVisionChance` | Poor sight |
| Vision: Random | `randomVisionChance` | Randomized sight |
| Hearing: Good | `goodHearingChance` | Pinpoint hearing |
| Hearing: Bad | `badHearingChance` | Poor hearing |
| Hearing: Pinpoint | `pinpointHearingChance` | Pinpoint hearing |
| Hearing: Normal | `normalHearingChance` | Normal hearing |
| Hearing: Poor | `poorHearingChance` | Poor hearing |
| Hearing: Random | `randomHearingChance` | Randomized hearing |
| Toughness: Tough | `toughnessChance` | Extra hit points (see §6.6) |
| Toughness: Normal | `normalToughnessChance` | Normal toughness |
| Toughness: Fragile | `fragileChance` | Reduced HP |
| Toughness: Random | `randomToughnessChance` | Randomized |
| Strength: Superhuman | `superhumanChance` | Superhuman strength |
| Strength: Weak | `weakChance` | Weak strength |
| Cognition: Navigate | `navigationChance` | Can navigate + use doors |
| Memory: Long | `memoryLongChance` | Long memory |
| Memory: Normal | `memoryNormalChance` | Normal memory |
| Memory: Short | `memoryShortChance` | Short memory |
| Memory: None | `memoryNoneChance` | No memory |
| Memory: Random | `memoryRandomChance` | Randomized |
| Armor | `zombieArmorFactor` | Zombie wears armor |
| Armor Effectiveness | `armorEffectivenessMultiplier` | Armor damage reduction multiplier |
| Armor Defense | `armorDefensePercentage` | Max defense percentage |
| Resistant | `resistantChance` | Resistant toughness |
| Max Hits | `maxHits` | Extra hits tough zombies resist (direct value, 1-99) |

### 6.3 Protocol v2 Bit-Encoded Payload

To minimize network overhead, the `ConfirmZombie` server command uses a **compact 23-character string** encoding:

```
Format: "BBBBBBBBBSXXXXXSYYYYYMM"
         ─────────┬────────────
         │        │        │ │
         │        │        │ └─ MM: maxHits (2 digits, zero-padded)
         │        │        └─── SYYYYY: sign digit + 5-digit abs Y
         │        └──────────── SXXXXX: sign digit + 5-digit abs X
         └───────────────────── BBBBBBBBB: 28 boolean flags as 9-digit decimal
```

**Bit layout (LSB first):**
| Bit | Flag | Bit | Flag |
|-----|------|-----|------|
| 0 | isSprinter | 14 | isTough |
| 1 | isShambler | 15 | isNormalToughness |
| 2 | hawkVision | 16 | isFragile |
| 3 | badVision | 17 | isRandomToughness |
| 4 | normalVision | 18 | isSuperhuman |
| 5 | poorVision | 19 | isNormalToughness2 |
| 6 | randomVision | 20 | isWeak |
| 7 | goodHearing | 21 | isRandomToughness2 |
| 8 | badHearing | 22 | hasNavigation |
| 9 | pinpointHearing | 23 | hasMemoryLong |
| 10 | normalHearing | 24 | hasMemoryNormal |
| 11 | poorHearing | 25 | hasMemoryShort |
| 12 | randomHearing | 26 | hasMemoryNone |
| 13 | isResistant | 27 | hasMemoryRandom |

**Protocol v3 extension:** If the zombie belongs to a registered ZombieModule, the payload includes `m = <moduleId>`.

### 6.4 Client-Side Property Application

**File:** `RegionManager_ZombieShared.lua` → `ServerSideProperties(zombie, data, sandboxOptions)`

Uses the **BLTRandomZombies reflection pattern**: temporarily overrides sandbox `ConfigOption` values, runs `makeInactive(true)/makeInactive(false)` cycle (which triggers Java `DoZombieStats()`), then restores originals.

**Critical fix implemented:** All config options are set **before** the makeInactive cycle so `DoZombieStats()` reads them in a single pass. The old approach would set speed, restore, then set other configs - causing `doZombieSpeed()` to re-randomize against defaults ~66% of the time.

**Sprinter retry loop:** Since PZ internally calls `Rand.Next(3)` in `doZombieSpeedInternal`, only `doSprinter()` sets `zombie.lunger = true` (the other paths run `doFakeShambler`). The code retries up to 15 times until `lunger` is true. Expected ~3 attempts for 99.5% reliability.

**Config options manipulated:**
- `ZombieLore.Speed` - Sprinter(1) / FastShambler(2) / Shambler(3)
- `ZombieLore.Cognition` - NavigateDoors(1) / Navigate(2) / Basic(3)
- `ZombieLore.Sight` - Eagle(1) / Normal(2) / Poor(3)
- `ZombieLore.Hearing` - Pinpoint(1) / Normal(2) / Poor(3)
- `ZombieLore.Strength` - Superhuman(1) / Normal(2) / Weak(3)
- `ZombieLore.Memory` - Long(1) / Normal(2) / Short(3) / None(4) / Random(5)

**Toughness** is applied after the cycle as direct HP manipulation:
- Tough: `health = random_base + maxHits` (e.g. 2+ HP)
- Normal: `health = random_base + 1.5`
- Fragile: `health = random_base + 0.5`

### 6.5 Speed Revalidation (Ownership Transfer Fix)

**Problem:** In multiplayer, when a zombie's authority owner changes (player moves away, another player gets closer), PZ calls `makeInactive(false)` which resets `speedType` to -1 and re-randomizes from sandbox defaults - losing the sprinter/shambler override.

**Solution:** A `SpeedTracker` flat array tracks all zombies with speed overrides. A round-robin revalidation checks `BATCH_SIZE=8` zombies per tick interval:

1. Read `zombie:getVariableString("zombiewalktype")`
2. Compare against `modData.Apocalipse_TSY_ExpectedSpeed` ("sprinter" or "shambler")
3. If mismatched and zombie is local (we are the auth owner), re-apply speed via `makeSprint()` or `makeShamble()`

This is O(batch) per tick, not O(all zombies).

### 6.6 Tough Zombie Hit System

**Network-authoritative hit tracking for tough zombies:**

```
Client (attacker)                Server                    All Clients
      │                            │                           │
      │ OnWeaponHitCharacter       │                           │
      │ ├─ target is tough?        │                           │
      │ ├─ Optimistic local:       │                           │
      │ │   setAvoidDamage(true)   │                           │
      │ │   setStaggerBack(true)   │                           │
      │ └─ Send "ZombieHitTough" ─►│                           │
      │                            │ Increment hit counter     │
      │                            │ Check if exhausted        │
      │                            │ Broadcast ───────────────►│
      │                            │ "ToughZombieHit"          │ Apply:
      │                            │                           │ ├─ Not exhausted:
      │                            │                           │ │   avoidDamage=true
      │                            │                           │ │   staggerBack=true
      │                            │                           │ └─ Exhausted:
      │                            │                           │     avoidDamage=false
      │                            │                           │     (zombie is killable)
```

Default `maxHits = 2` (configurable per-region or per-module, range 1-99).

---

## 7. Zombie Module System (Boss Zombies)

### 7.1 Module Registration API

**File:** `RegionManager_ZombieModules.lua` (shared)

External mods register special zombie types by outfit name. When the `ConfirmZombie` pipeline encounters a matched outfit, it uses **guaranteed stat overrides** instead of probabilistic region rolling.

```lua
RegionManager.ZombieModules.register({
    id = "nemesis",
    outfitNames = {"Nemesis"},          -- Outfit trigger(s)
    stats = {                           -- Guaranteed properties (no RNG)
        isSprinter = true,
        isTough = true,
        maxHits = 10,
        bossHealth = 50,                -- Direct HP override
        killBonus = 25,                 -- Flat kill bonus
    },
    sounds = {                          -- Client-side sound config
        suppressVanilla = true,         -- Mute vanilla zombie voice
        theme = { name = "BossTheme", range = 60, loop = true },
        onDetect = { name = "BossDetect", range = 40 },
        periodic = {
            { names = {"BossRoar1", "BossRoar2"}, cooldownTicks = 300, chance = 50 }
        },
        onHit = {
            { names = {"BossHit1", "BossHit2"}, chance = 80 }
        },
    },
    behavior = {                        -- Client-side AI tweaks
        redirectToPlayer = true,        -- Pathfind to owning player
        redirectCooldownTicks = 300,
        detectionRange = 80,
    },
})
```

**Lookup:** `_registry[outfitName]` → O(1) outfit-based lookup. `_byId[moduleId]` → O(1) ID-based lookup.

### 7.2 Client-Side Module Engine

**File:** `RegionManager_ZombieModuleClient.lua`

After `ConfirmZombie` with a module ID (`args.m`), the client initializes tracking for that zombie:

- **Theme music** - Distance-based start/stop with gradual fade-out (180 ticks ≈ 3 seconds)
- **Detection sound** - One-shot announcement when player first approaches
- **Periodic sounds** - Cooldown-gated random sound picks (e.g. roars)
- **Hit sounds** - Chance-based sound on `OnWeaponHitCharacter`
- **Vanilla suppression** - Stops `ZombieVoiceSprinting`, `ZombieVoice`, `MaleZombieVoice`, `FemaleZombieVoice` every tick
- **AI redirect** - If `redirectToPlayer` is set and the zombie is locally owned, periodically calls `zombie:pathToLocationF()` toward the player
- **Boss health** - Sets `zombie:setHealth(bossHealth)` if module defines it

Theme fade-outs are decoupled from zombie lifecycle - they finish even after the zombie dies.

---

## 8. Sprinter Scream System (Apocalipse_TSY)

**Files:** `Apocalipse_TSY_Main.lua` (client) + `Apocalipse_TSY_Server.lua` (server)

Originally based on SIMBAproduz's "theySEE YOU" mod, this system makes sprinter zombies scream when they detect or chase the player.

### 8.1 Scream Types

| Type | Trigger | Range | Limit |
|---|---|---|---|
| **Discovery scream** | Sprinter sees player for first time | `FarRange` (default 150 tiles) | Once per zombie |
| **Close-up scream** | Sprinter enters `NearRange` (8 tiles) | Point-blank | Once per zombie |
| **Chase scream** | During sustained pursuit after discovery | `FarRange` | Cooldown-gated |

Each zombie gets a max of `MaxScreamsPerZombie = 3` total screams (discovery + close-up + chase).

**Scream processing flow (`OnZombieUpdate`):**
1. Skip if: dead, fake-dead, on floor, in vehicle, not sprinter, not targeting player, outside `MaxProcessDistance`
2. Check `TickRate`-based throttle (default every 6 ticks)
3. Check `CanSee(player)` - zombie must have line of sight
4. Phase 1 - Discovery: if `HasFarScreamed == nil` and `dist > NearRange`, roll `ScreechChance` (default 60%)
5. Phase 2 - Close-up: if `HasNearScreamed == nil` and `dist ≤ NearRange`, play with delay (`NearDelayTicks = 10`)
6. Phase 3 - Chase: after both discovery and close-up, roll `ChaseScreechChance` (default 50%) with `ChaseCooldownHours`

**Sprinter detection** checks `zombie:getVariableString("zombiewalktype")` for the substring "sprint" (case-insensitive).

### 8.2 Cluster Anti-Spam

Prevents scream stacking when many sprinters are near each other:

- **Cluster radius:** 35 tiles (configurable)
- **Cluster cooldown:** ~36 seconds (`ClusterCooldownHours = 0.01`)
- **Max screams per cluster:** 1

A global `Apocalipse_TSY_ClusterEvents` table tracks `{x, y, t}` entries. Before any scream, `CanClusterScream()` checks if the event count within the radius and time window exceeds the limit.

### 8.3 Horde Alert Mechanic

When a sprinter screams, `TriggerAlert()` fires `addSound()` at the player's position with a default radius of 80 tiles. This attracts nearby zombies, creating a genuine horde-pull effect. The screaming zombie itself is temporarily immune to its own alert (via `IgnoreAlertUntil` modData).

On the server side, `PullHorde()` fires 5 delayed `addSound()` pulses (at tick 0, 20, 40, 60, 80) for a sustained attraction effect.

### 8.4 Sound Architecture

- **62 voice slots** - `ABMIS_01.mp3` through `ABMIS_62.mp3`
- **Bag-based shuffle** - Fisher-Yates shuffle ensures all voices play before repeating, with anti-repeat for consecutive picks
- **Volume system:**
  - `GlobalVolume × FarVolume × PeriodMultiplier × DistanceFalloff` for discovery screams
  - `GlobalVolume × NearVolume × PeriodMultiplier` for close-up screams
  - Separate day/night volume multipliers
- **Script definition:** All 62 sounds defined in `Apocalipse_TSY_Sounds.txt` under `module Base` with `category = Vehicle`, `distanceMax = 150`, `is3D = true`

---

## 9. AnimSets (Sprinter Animations)

Custom animation trigger sets for sprinter zombies are in `media/AnimSets/zombie/`:

```
lunge/              ← Attack animation overrides
├── defaultLunge.xml        (base lunge, SpeedScale=0.80)
├── sprint1..5.xml          (extend defaultLunge with sprint-specific anims)
lunge-network/      ← Network-replicated lunge variants
├── defaultLunge.xml
├── sprint1..5.xml
walktoward/         ← Movement toward target
├── sprintToward.xml        (base sprint toward, SpeedScale=0.80)
├── sprint1..5.xml          (extend sprintToward)
├── sprintFallback1..5.xml  (fallback variants)
walktoward-network/ ← Network-replicated movement
├── sprintToward.xml
├── sprint1..5.xml
├── sprintFallback1..5.xml
```

Each sprint variant uses `x_extends="defaultLunge.xml"` or `x_extends` on the base node and is conditioned on `zombieWalkType` matching `sprint1`..`sprint5`. The `deferredBoneAxis=Y` enables root motion on the Y axis.

---

## 10. Sandbox Options

Region controls under page `RegionManager`:

| Option | Type | Default | Description |
|---|---|---|---|
| `AutomaticSafeZones` | boolean | false | Cover fixed map bounds outside PvP regions with automatic non-PvP zones; requires server restart |
| `EnforcePVP` | boolean | true | Legacy global toggle; latest implementation uses each region's `forcedPvP` property instead |

Sprinter scream options under page `Apocalipse_TSY`:

| Option | Type | Default | Range | Description |
|---|---|---|---|---|
| `TimeMode` | integer | 0 | 0-2 | 0=always, 1=day only, 2=night only |
| `ScreechChance` | integer | 60 | 0-100 | Discovery scream % chance |
| `ChaseScreechChance` | integer | 50 | 0-100 | Chase scream % chance |
| `ChaseCooldownHours` | double | 0.03 | 0.0001-0.1 | Hours between chase screams |
| `GlobalVolume` | double | 1.0 | 0.1-3.0 | Master volume multiplier |
| `FarVolume` | double | 0.08 | 0.01-1.0 | Discovery scream base volume |
| `NearVolume` | double | 1.0 | 0.1-3.0 | Close-up scream volume |
| `FarRange` | integer | 150 | 10-300 | Max distance for discovery scream |
| `MaxProcessDistance` | integer | 220 | 50-400 | Max distance to process zombie |
| `TickRate` | integer | 6 | 1-20 | Ticks between processing per zombie |

Additional options exist for cluster radius, cluster cooldown, max cluster screams, alert radius, alert enable, day/night volume multipliers, and debug mode (`RegionManager.DebugMode`).

---

## 11. File Reference

### Shared (client + server)
| File | Purpose |
|---|---|
| `RegionManager_Config.lua` | Region definitions, category defaults, type annotations |
| `RegionManager_JSON.lua` | Custom JSON parser/encoder (no external dependencies) |
| `RegionManager_ZombieShared.lua` | Property application (`ServerSideProperties`), speed revalidation, tough zombie hit handling, payload decoding, sandbox option caching |
| `RegionManager_ZombieModules.lua` | Module registry for boss/special zombie types |

### Server
| File | Purpose |
|---|---|
| `RegionManager_Server.lua` | Zone registration, client command dispatch, JSON I/O |
| `RegionManager_AutoSafeZones.lua` | Auto-safe zone generation via rectangle subtraction |
| `RegionManager_PVP_Server.lua` | PVP state broadcast relay |
| `RegionManager_ZombieServer.lua` | Zombie decision pipeline, ModData storage, client command handler |
| `RegionManager_ZombieServerHelper.lua` | Chance aggregation, RNG, payload encoding, region lookup |
| `Apocalipse_TSY_Server.lua` | Server-side scream validation, horde pull, cluster management |

### Client
| File | Purpose |
|---|---|
| `RegionManager_Client.lua` | Zone data storage, notification display, server command handler |
| `RegionManager_ClientTick.lua` | Central tick dispatcher, zone enter/exit detection |
| `RegionManager_PVP.lua` | Optional safety state enforcement from current regions |
| `RegionManager_ZombieClient.lua` | Spawn hook, pending queue, payload decode, SpeedTracker |
| `RegionManager_ZombieModuleClient.lua` | Boss zombie sound/behavior engine |
| `RegionManager_AdminPanel.lua` | Admin UI for region list and teleportation |
| `Apocalipse_TSY_Main.lua` | Sprinter scream detection, sound playback, alert triggers |

### Data / Config
| File | Purpose |
|---|---|
| `mod.info` | Mod metadata |
| `sandbox-options.txt` | Sandbox option definitions |
| `scripts/Apocalipse_TSY_Sounds.txt` | Sound definitions for 62 scream voice slots |
| `AnimSets/zombie/` | Custom sprinter animation trigger sets |
| `sound/` | ABMIS_01..62.mp3 voice files |

## Development and Workshop publishing

See [AGENTS.md](AGENTS.md) for the architecture map and contributor workflow. Run `npm ci`, `npm test`, `npm run build`, and `npm run test:build`. Builds go to `build/ApocalipseBR Regioes` (or `PZ_BUILD_ROOT`), preserve game mod ID `ApocalipseBR_Regioes`, and validate the actual packaged Lua and assets.

The GitHub Actions flow matches Music Uploads: PRs validate/build an artifact; master pushes or manual runs publish Workshop item `3706462687` through the shared Radio publisher on the `pz-workshop` self-hosted runner. Confirmed or unconfirmed uploads request a server restart. The repository needs access to the shared Steam session and PZManager secrets described in `AGENTS.md`.
