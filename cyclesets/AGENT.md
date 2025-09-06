# Agent: CycleSets for OBS

## 🧭 Purpose
CycleSets is an OBS Studio Lua script agent that manages **profiles of scenes** and enables controlled cycling between them.  
Unlike OBS’s default *Next/Previous Scene* hotkeys, this agent allows users (or calling systems) to define **ordered subsets of scenes** and cycle through them using **multi-tap, per-profile hotkeys**.

---

## 🌍 Environment
- **Host Application:** OBS Studio (28+)  
- **Language:** Lua 5.2 (OBS Script API)  
- **Platforms:** Windows, macOS, Linux  
- **Dependencies:** None (uses only OBS built-in APIs)  
- **Persistence:** Profiles, last-selected indices, and hotkey bindings are stored in OBS’s script settings.  

---

## ⚡ Capabilities
1. **Profile Management**
   - Create, rename, delete scene profiles.  
   - Each profile is an ordered list of OBS scenes.  

2. **Scene Management**
   - Add/remove OBS scenes to/from profiles via UI.  
   - Reorder scenes (Up/Down).  
   - Auto-prune deleted OBS scenes from all profiles.  

3. **Cycling**
   - Cycle only within the Active Profile’s scenes.  
   - Multi-tap cycling:
     - First press → recalls last selected scene.  
     - Additional presses within **Tap Window (ms)** → advance or go back.  
     - Pause longer than window resets to last selected.  

4. **Hotkeys**
   - **Per-profile hotkeys**:  
     - `Cycle Scenes (Profile: <Name>): Next`  
     - `Cycle Scenes (Profile: <Name>): Previous`  
   - Hotkeys are registered when profiles exist and automatically **removed if profiles are deleted**.  
   - Renaming a profile preserves hotkey bindings.  

5. **Persistence**
   - Profiles, last selected scene indices, and hotkey bindings persist across OBS restarts.  

---

## 🚦 Constraints
- Cannot modify or delete OBS scenes outside user-defined profiles.  
- Scene names must match OBS’s current scene list (auto-pruning handles deletions).  
- Scene renames in OBS are treated as “delete + add”; user must re-add.  
- Only cycles through explicitly selected profile scenes (ignores all others).  

---

## 🗂️ State Model
```lua
profiles = {
  ["Show A"] = { "Cam 1", "Cam 2", "Slides" },
  ["Show B"] = { "Intro", "Game", "Break" }
}

active_profile = "Show A"

last_selected_idx_by_profile = { ["Show A"] = 2, ["Show B"] = 1 }

tap_state = {
  ["Show A"] = { next_deadline = 0, prev_deadline = 0, active_idx_next = nil, active_idx_prev = nil }
}

hotkey_ids_by_profile = {
  ["Show A"] = { next_id = <id>, prev_id = <id> }
}