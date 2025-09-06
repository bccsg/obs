# CycleSets for OBS

**CycleSets** is an OBS Studio Lua script that lets you define **profiles of scenes** and cycle through them with **multi-tap hotkeys**.  

Unlike the default *Next/Previous Scene* hotkeys (which cycle through all scenes in your collection), CycleSets gives you fine control over **which scenes are included**, their **order**, and provides **per-profile hotkeys**.  

---

## ✨ Features

- **Profiles**  
  - Create, rename, and delete multiple scene profiles.  
  - Each profile contains an ordered list of scenes.  
  - Independent hotkeys per profile.  

- **UI-driven scene selection**  
  - Pick scenes directly from OBS’s scene list (no typing names).  
  - Add, remove, and reorder with buttons.  

- **Multi-tap hotkeys**  
  - First press → recalls the last selected scene.  
  - Further presses within a short window → advance/step back.  
  - Pause longer than the window resets to last selected.  

- **Per-profile hotkeys**  
  - `Cycle Scenes (Profile: <Name>): Next`  
  - `Cycle Scenes (Profile: <Name>): Previous`  
  - Hotkeys are created when profiles exist, and automatically removed if profiles are deleted.  
  - Renaming a profile migrates its hotkey bindings automatically.  

- **Auto-pruning**  
  - If you delete a scene in OBS, it is automatically removed from all profiles.  

- **Persistence**  
  - Profiles, last selected scene index, and hotkey bindings persist across OBS restarts.  

---

## 🖥️ Environment

- OBS Studio **28+**  
- Lua **5.2** (via OBS Script API)  
- Windows / macOS / Linux  

---

## 📥 Installation

1. Download the latest release of `cycle_sets.lua`.  
2. In OBS, go to **Tools → Scripts**.  
3. Click the **+** button and load `cycle_sets.lua`.  
4. The CycleSets UI will appear in the Scripts window.  

---

## ⚙️ Usage

1. **Create a Profile**  
   - Enter a name and click **Add Profile**.  

2. **Add Scenes**  
   - Select a scene from the “Available Scenes” dropdown.  
   - Click **Add Selected Scene → Profile**.  
   - Repeat for all scenes you want in that profile.  

3. **Reorder Scenes**  
   - Use **Move Up/Move Down** to change order.  

4. **Assign Hotkeys**  
   - Go to **Settings → Hotkeys**.  
   - Assign keys for:
     - `Cycle Scenes (Profile: <Name>): Next`  
     - `Cycle Scenes (Profile: <Name>): Previous`  

5. **Use Multi-Tap Cycling**  
   - First press → recalls last selected scene.  
   - Additional presses within the **Tap Window (default 600ms)** cycle through.  
   - Pause longer than the Tap Window resets to last selected.  

---

## 🛠️ Options

- **Tap Window (ms)**  
  Adjust the maximum interval between taps (150–2000 ms).  

- **Persist Last Selected**  
  Store the last selected scene per profile across sessions.