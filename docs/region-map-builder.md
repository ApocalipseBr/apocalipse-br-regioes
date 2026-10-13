# Region map builder (42.18)

The admin panel's New Region and Edit Region buttons open a two-column editor:
an embedded world map on the left and a scrollable properties form on the right.
The window fits within the screen. Historical 42.14 UI is unchanged.

The map uses the same B42 API v3 data, street styling, annotations, and input
approach as ApocalipseBR-PvPTerritory's FactionMapWidget, without requiring that mod.

- New regions start in drawing mode. Drag a rectangle, then release to finish.
- Draw Region arms drawing mode again. Right-click cancels; an interrupted
  redraw restores the previous corners.
- Outside drawing mode, left drag pans and the wheel zooms around the cursor.
- Right-click the map to set either corner separately.
- Outside releases finish the drag at the viewport edge and release input state.
- Selection dimensions use inclusive tile bounds, matching region registration.

The form exposes speed and toughness plus the currently implemented deterministic
traits: cognition (door opening), sight, and hearing. Memory and strength remain
unexposed because they have no active selection/application path in this version.

Percentages accept 0 through 100. Blank removes the custom override, allowing
category properties and then sandbox defaults to apply. Explicit 0 is retained,
particularly for disabling door opening. Sense percentages are priority
thresholds, not weighted distributions: best, normal, poor, then random.
Good/Pinpoint Hearing and Bad/Poor senses are aliases; their maximum applies.
Unmatched rolls fall back to sandbox lore. Hover the trait rules button for help.

PvP behavior supports inherit/neutral, safe zone, and PvP zone. Editing preserves
the region's ID unless changed, category list, enabled state, elevation, and
properties outside the form. Submission is blocked during drawing and for
invalid percentages. Existing server admin validation and commands are used.

The optional entry message replaces the announcement checkboxes. A nonempty
message displays once on entry, including for old regions with announcement
flags disabled. Empty or whitespace-only text is silent; leaving a region never
displays a message. Clearing the field saves an empty override to suppress any
category message. Entry/exit callbacks for gameplay modules still run.

`tests/map_picker_spec.cjs` checks drag/pan/zoom, cancellation, outside releases,
scroll bounds, property round trips, and edit payloads with Lua API stubs. Run the
repository test/build/package checks. Actual map appearance, font scaling,
tooltips, and multiplayer interaction still require a B42.18 in-game check.
