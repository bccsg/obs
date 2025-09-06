# CycleSets for OBS

CycleSets is an OBS Studio Lua script to define ordered sets of scenes and cycle through them with multi‑tap hotkeys.

Note: Cycles the Preview scene in Studio Mode (not Program).

For contributors and AI assistants, see `cyclesets/AGENTS.md` for a detailed spec.

---

## Features

- Multiple sets: Create, rename, delete per‑project CycleSetSceneLists (scene sets).
- UI scene picking: Add, remove, reorder scenes from OBS’s scene list.
- Multi‑tap hotkeys: First press recalls last selected; subsequent taps within a window move next/previous; pause resets.
- Per‑set hotkeys: CycleSets (Set: <Name>): Next/Previous; created/removed automatically; bindings migrate on rename.
- Auto‑pruning: Deleted/missing OBS scenes are pruned; updates persist automatically on scene/collection changes.
- Persistence: Sets and hotkey bindings persist; last‑selected scene index is session‑only.

---

## Requirements

- OBS Studio 28+
- Lua 5.2 (via OBS Script API)
- Windows / macOS / Linux

---

## Installation

1. Download `cyclesets.lua` from this repository/release.
2. In OBS, open Tools → Scripts.
3. Click + and load `cyclesets.lua`.
   - If you cloned this repo, the file lives at `cyclesets/cyclesets.lua`.

---

## Usage

1. Create a set: Enter a name → Add CycleSetSceneList.
2. Add scenes: Pick from Available Scenes → Add Selected Scene → CycleSetSceneList. Reorder or remove as needed.
3. Assign hotkeys: Settings → Hotkeys → bind for your set:
   - CycleSets (Set: \<Name>): Next
   - CycleSets (Set: \<Name>): Previous
4. Use it: Press Once = last selected; press again within the Tap Window to advance; use Previous to step back.

Tip: Choose the active set from the script UI (Active CycleSetSceneList) before using hotkeys.
Note: Ensure Studio Mode is enabled; the script switches the Preview scene.

---

## Options

- Tap Window (ms): 150–2000; controls the max interval between taps.
 
