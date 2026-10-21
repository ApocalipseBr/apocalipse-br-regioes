# Per-region forced PvP

Implemented in the latest `42.18` mod folder. Historical `42.14` is unchanged.

```lua
customProperties = {
    pvpEnabled = true,
    forcedPvP = false -- optional PvP; omit or set true to force PvP
}
```

Category defaults merge first, with custom properties overriding them. After
merging, a PvP region with no `forcedPvP` value receives `true`. The resolved
boolean travels in `AllZoneBoundaries` alongside `pvpEnabled`. Public resolved
scalar properties also travel as `properties` for tooltip/scoring addons;
non-scalar settings are omitted from this extra bag.

The client PvP module uses the region policy regardless of the legacy global
`RegionManager.EnforcePVP` setting. `forcedPvP=false` leaves vanilla safety and
cooldown control with the player. It does not enable protection against PvP;
native non-PvP protection still comes from `pvpEnabled=false` regions.

Overlaps: any explicit safe region vetoes enforcement; otherwise any forced PvP
region requires safety off. Optional PvP regions do not veto another region's
forced policy. Neutral regions have no effect. Exiting releases enforcement
without switching safety on. Pending vanilla toggles are not resent.

The map builder selector supports category inheritance, explicit forced
and explicit optional values. New regions default to `false` in the form and
server AddRegion handler; existing raw missing values are not migrated, including
on edit/save with inheritance selected. Missing/true means forced in a PvP
region; false means optional. Labels explain that enforcement overrides sandbox
settings and applies only in PvP-enabled regions.

The existing **Debug logs** sandbox option (`RegionManager.DebugMode`, default
false) controls policy-transition and safety-request diagnostics. Unchanged
policies do not log on every tick. The legacy sandbox
option remains for save compatibility and historical versions; its latest EN
tooltip explains that the per-region property supersedes it.

This changes the existing client safety convenience, not server anti-cheat or
native damage handling. Deploy updated server/client mod files together.

Verification: `npm test` covers missing/true/false values under both sandbox
toggle values, safe/forced/optional overlaps, pending toggle handling, payload
defaults and false preservation, scalar transport and map-builder serialization.
`npm run build` and `npm run test:build` validate the packaged implementation.
Actual multiplayer safety/network timing remains to be tested in game.
