# CycleSets for OBS — AI Assistants Spec

This document provides a precise, implementation‑level specification of `cyclesets.lua` for AI coding assistants. It captures behavior, state, hotkeys, persistence, and UI contracts to enable safe refactors and feature work.

## Purpose

Define named, ordered sets of scenes (CycleSetSceneLists) and cycle through them via per‑set Next/Previous hotkeys using a multi‑tap interaction model.

## Runtime

- OBS Studio 28+ (Windows/macOS/Linux)
- Lua 5.2 via OBS Script API (`obslua`)
- Operates on Studio Mode Preview (not Program)

## Core Concepts

- CycleSetSceneList: Named list of scene names in a specific order.
- Active CycleSetSceneList: The set targeted by UI actions; stored in settings.
- Multi‑tap Window: Time window (ms) within which repeated taps advance; separate timers per direction (Next/Prev) per set.
- Per‑Set Hotkeys: Each set has two actions registered: Next and Previous.

## State (in‑memory)

- `cyclesets: map<string, list<string>>` — set name → ordered scene names.
- `active_cycleset: string` — current set name (defaults to `"Default"`).
- `tap_window_ms: int` — multi‑tap window; default 600; UI‑configurable (150–2000 step 10).
- `last_selected_idx_by_cycleset: map<string,int>` — last selected index per set (session‑only).
- `tap_state_by_cycleset: map<string, {next_deadline:int, prev_deadline:int, active_idx_next:int?, active_idx_prev:int?}>` — transient multi‑tap state.
- `hotkey_ids_by_cycleset: map<string, {next_id, prev_id}>` — registered hotkey IDs.
- `hotkey_callbacks_by_cycleset: map<string, {next_cb, prev_cb}>` — retained callbacks.
- `last_settings, last_props` — latest OBS settings/props handles for UI/persistence.

## Persistence (OBS settings)

Saved on `script_save` and during edits via `persist_now()` where possible:

- `cyclesets` (array of objects):
  - object fields: `name: string`, `scenes: array<{scene:string}>`
- `active_cycleset: string`
- `tap_window_ms: int`
- Hotkey bindings per set/direction:
  - Key format: `hotkey_bindings::<cycleset>::next` and `...::prev`
  - Value: `obs_data_array` returned by `obs_hotkey_save(id)`

Not persisted: `last_selected_idx_by_cycleset` (session‑only by design).

## UI (Properties) Contract

Property IDs (string constants):

- `cycleset_select` — Active CycleSetSceneList dropdown
- `new_cycleset_name` — Text field used for Add/Rename
- `available_scene` — Dropdown of current OBS scenes
- `cycleset_scene_select` — Dropdown of scenes within active set
- `tap_window_ms` — Int input (150–2000)

Buttons and actions:

- Add CycleSetSceneList → creates a new set from `new_cycleset_name`, selects it, registers hotkeys, persists.
- Rename Active CycleSetSceneList → migrates data and hotkeys from old name to `new_cycleset_name`, selects new, persists.
- Delete Active CycleSetSceneList → removes set and its hotkeys/bindings; selects or creates `Default`, persists.
- Add Selected Scene → appends `available_scene` to active set (no duplicates), persists.
- Move Up / Move Down → reorders the selected scene within the active set, persists.
- Remove Selected From CycleSetSceneList → removes selected scene from active set, persists.

UI Lists refresh on: property changes, scene list changes, collection changes, and script load/update.

## Hotkeys

Action labels (per set):

- `CycleSets (Set: <Name>): Next`
- `CycleSets (Set: <Name>): Previous`

Internal action names (unique IDs):

- Next: `cycle_cycleset_next::<slug(name)>`
- Prev: `cycle_cycleset_prev::<slug(name)>`

Hotkey lifecycle:

- Register on script load for all sets; load saved bindings if present.
- Add: register new set’s hotkeys and load any existing bindings.
- Rename: save old bindings, unregister old IDs, register new IDs, load into new IDs, move bindings in settings, erase old keys.
- Delete: unregister (if supported) and erase saved bindings for that set.

## Scene Switching Behavior

- Switching targets Preview: `obs_frontend_set_current_preview_scene(src)`.
- Scene resolution by name: `obs_get_source_by_name` with release.
- Scene list used for UI comes from `obs_frontend_get_scenes()`; names sorted case‑insensitively.

## Multi‑Tap Algorithm

Concepts: timers per set/direction; last‑selected index per set; wrap‑around.

Next (on hotkey pressed=true):

1. If the active set has no scenes → return.
2. If `now > next_deadline` OR `active_idx_next` is nil:
   - `idx ← clamp(last_selected_idx[pname] or 1, 1..N)`
   - Switch to `list[idx]` (Preview)
   - `active_idx_next ← idx`; `next_deadline ← now + tap_window_ms`
   - Update `last_selected_idx[pname] ← idx`
3. Else (within window):
   - `active_idx_next ← (active_idx_next % N) + 1` (wrap)
   - Switch to new scene; extend deadline; update last‑selected.

Previous mirrors Next with its own state:

- First tap recalls last‑selected; within window: `((active_idx_prev + N - 2) % N) + 1` (wrap backward).

Window separation: Next and Previous maintain independent timers and indices; using one does not extend the other’s window.

## Auto‑Pruning

- On OBS events `SCENE_LIST_CHANGED` or `SCENE_COLLECTION_CHANGED`, rebuild the set lists keeping only scenes present in OBS; clamp last‑selected indices; refresh UI; persist.
- If the current OBS scene list is empty (e.g., during startup), pruning is skipped to avoid wiping sets.

## OBS Script Interface

- `script_description()` — Returns multiline help (usage + hotkeys).
- `script_properties()` — Builds UI with lists/buttons/inputs and callbacks; seeds lists and syncs the active selection.
- `script_update(settings)` — Applies `tap_window_ms`, responds to active set changes, refreshes lists and selections.
- `script_load(settings)` — Loads persisted data, prunes, registers events and hotkeys, refreshes UI.
- `script_save(settings)` — Persists cyclesets, active set, tap window, and current hotkey bindings.

## Edge Cases & Guarantees

- Empty set: hotkeys no‑op.
- Duplicates: not added to a set.
- Rename to existing name: blocked.
- Tap window min/max: clamped by UI (150–2000).
- Active set always exists: ensures a `Default` set when needed.
- Last‑selected index: clamped to set size after edits/pruning; not persisted across restarts.

## Limitations

- Preview only: does not switch Program; requires Studio Mode for visible effect.
- No per‑scene delays or transitions are configured here (uses OBS defaults).

## Extension Points (safe directions)

- Add a toggle to target Program instead of Preview (ensure safe defaults).
- Persist last‑selected indices (add to settings) if desired.
- Per‑set tap window overrides (store alongside set data).
- Export/import sets to JSON for sharing.

## Naming & Formatting

- “CycleSetSceneList” is the internal term used in code/UI; README presents it as “scene set” for clarity while keeping labels consistent with hotkeys.

---

If you modify state shape, property IDs, or hotkey labels, update this spec and the README to maintain alignment.

