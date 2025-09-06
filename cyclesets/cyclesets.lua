------------------------------------------------------------
-- CycleSets for OBS
-- Version: 1.0.0
-- Author: Matthew Chng
--
-- Description:
--   Define multiple CycleSetSceneLists ("cyclesets"), each an ordered list of scenes,
--   and cycle through them with per-CycleSetSceneList, multi-tap hotkeys.
--
-- Features:
--   • UI-driven scene selection (no typing names).
--   • Multiple CycleSetSceneLists (Add/Rename/Delete).
--   • Per-CycleSetSceneList hotkeys (Next/Previous).
--   • Hotkeys removed if a CycleSetSceneList is deleted; migrated on rename.
--   • Multi-tap: first press = last selected; taps within window advance.
--   • Auto-pruning when OBS scenes are deleted or collections change.
--   • Persistence for cyclesets, hotkeys, and last selected indices.
--
-- Environment: OBS Studio 28+ (Windows/macOS/Linux), Lua 5.2
------------------------------------------------------------

obs = obslua

------------------------------------------------------------
-- State
------------------------------------------------------------

local cyclesets = {}                     -- map<string CycleSetSceneList, list<string scene_name>>
local active_cycleset = "Default"

local tap_window_ms = 600               -- configurable

-- Last selected scene index per CycleSetSceneList (persisted)
local last_selected_idx_by_cycleset = {} -- map<string,int>

-- Tap state per CycleSetSceneList (transient)
local tap_state_by_cycleset = {}                    -- map<string,{next_deadline,prev_deadline,active_idx_next,active_idx_prev}>

local hotkey_ids_by_cycleset = {}        -- map<string,{next_id,prev_id}>
local hotkey_callbacks_by_cycleset = {}  -- map<string,{next_cb,prev_cb}>


-- We keep bindings in settings (persisted) under keys per cycleset.
-- We'll assemble keys as: "hotkey_bindings::<cycleset>::next"/"prev"

-- Remember last obs settings reference (used by UI callbacks)
local last_settings = nil
-- Remember last-created props object so script_update can refresh UI lists
local last_props = nil
-- Forward declarations for functions used by hotkey callbacks
local cycle_next_for, cycle_prev_for

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function slug(name)
    name = (name or ""):lower()
    name = name:gsub("%s+", "_")
    name = name:gsub("[^%w_]", "")
    return name
end

local function mono_ms()
    if obs.os_gettime_ns then
        return math.floor(obs.os_gettime_ns() / 1000000)
    else
        return os.time() * 1000
    end
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function ensure_cycleset_state(pname)
    tap_state_by_cycleset[pname] = tap_state_by_cycleset[pname] or {
        next_deadline = 0, prev_deadline = 0,
        active_idx_next = nil, active_idx_prev = nil
    }
end

local function list_current_scene_names_sorted()
    local names = {}
    local scenes = obs.obs_frontend_get_scenes()
    if scenes ~= nil then
        for _, sc in ipairs(scenes) do
            table.insert(names, obs.obs_source_get_name(sc))
        end
        for _, sc in ipairs(scenes) do obs.obs_source_release(sc) end
    end
    table.sort(names, function(a,b) return string.lower(a) < string.lower(b) end)
    return names
end

local function current_scene_name()
    local cur = obs.obs_frontend_get_current_scene()
    if cur == nil then return nil end
    local nm = obs.obs_source_get_name(cur)
    obs.obs_source_release(cur)
    return nm
end

-- Direct scene switch helper: perform immediately. Hotkey callers already
-- check for empty cycleset lists and return quickly, so this function
-- simply resolves the named source and sets the current scene.
local function set_scene_by_name(name)
    if not name or name == "" then return end
    local src = obs.obs_get_source_by_name(name)
    if src ~= nil then
        obs.obs_frontend_set_current_preview_scene(src)
        obs.obs_source_release(src)
    end
end

local function index_of(list, value)
    for i, v in ipairs(list) do if v == value then return i end end
    return nil
end

local function ensure_defaults()
    if next(cyclesets) == nil then
        cyclesets["Default"] = {}
        active_cycleset = "Default"
    end
    if not cyclesets[active_cycleset] then
        for k,_ in pairs(cyclesets) do active_cycleset = k; break end
    end
end

local function clamp_last_idx(pname)
    local N = #(cyclesets[pname] or {})
    if N == 0 then
        last_selected_idx_by_cycleset[pname] = nil
        return
    end
    local cur = last_selected_idx_by_cycleset[pname] or 1
    last_selected_idx_by_cycleset[pname] = clamp(cur, 1, N)
end

------------------------------------------------------------
-- Persistence (cyclesets, last-selected, hotkeys, settings)
------------------------------------------------------------
local function settings_key_for_binding(cycleset, which)
    -- which = "next" | "prev"
    return "hotkey_bindings::" .. cycleset .. "::" .. which
end

local function save_cyclesets_to_settings(settings)
    -- cyclesets
    local arr = obs.obs_data_array_create()
    for name, scenes in pairs(cyclesets) do
        local obj = obs.obs_data_create()
        obs.obs_data_set_string(obj, "name", name)
        local sa = obs.obs_data_array_create()
        for _, s in ipairs(scenes) do
            local so = obs.obs_data_create()
            obs.obs_data_set_string(so, "scene", s)
            obs.obs_data_array_push_back(sa, so)
            obs.obs_data_release(so)
        end
        obs.obs_data_set_array(obj, "scenes", sa)
        obs.obs_data_array_push_back(arr, obj)
        obs.obs_data_array_release(sa)
        obs.obs_data_release(obj)
    end
    obs.obs_data_set_array(settings, "cyclesets", arr)
    obs.obs_data_array_release(arr)

    -- active cycleset
    obs.obs_data_set_string(settings, "active_cycleset", active_cycleset)

    -- global settings
    obs.obs_data_set_int(settings, "tap_window_ms", tap_window_ms or 600)

    -- hotkey bindings (save current IDs to arrays)
    for pname, ids in pairs(hotkey_ids_by_cycleset) do
        if ids.next_id then
            local arrn = obs.obs_hotkey_save(ids.next_id)
            obs.obs_data_set_array(settings, settings_key_for_binding(pname, "next"), arrn)
            obs.obs_data_array_release(arrn)
        end
        if ids.prev_id then
            local arrp = obs.obs_hotkey_save(ids.prev_id)
            obs.obs_data_set_array(settings, settings_key_for_binding(pname, "prev"), arrp)
            obs.obs_data_array_release(arrp)
        end
    end
end

-- Convenience: persist current state if settings ref is available
local function persist_now()
    if last_settings then
        save_cyclesets_to_settings(last_settings)
    end
end

local function load_cyclesets_from_settings(settings)
    cyclesets = {}
    active_cycleset = obs.obs_data_get_string(settings, "active_cycleset")
    -- cyclesets
    local arr = obs.obs_data_get_array(settings, "cyclesets")
    if arr ~= nil then
        for i = 0, obs.obs_data_array_count(arr) - 1 do
            local obj = obs.obs_data_array_item(arr, i)
            local name = obs.obs_data_get_string(obj, "name")
            local scenes = {}
            local sa = obs.obs_data_get_array(obj, "scenes")
            if sa ~= nil then
                for j = 0, obs.obs_data_array_count(sa) - 1 do
                    local so = obs.obs_data_array_item(sa, j)
                    local nm = obs.obs_data_get_string(so, "scene")
                    if nm and nm ~= "" then table.insert(scenes, nm) end
                    obs.obs_data_release(so)
                end
                obs.obs_data_array_release(sa)
            end
            if name and name ~= "" then cyclesets[name] = scenes end
            obs.obs_data_release(obj)
        end
        obs.obs_data_array_release(arr)
    end

    ensure_defaults()

    -- global settings
    local tw = obs.obs_data_get_int(settings, "tap_window_ms")
    tap_window_ms = (tw and tw > 0) and tw or 600

    -- clamp indices
    for pname,_ in pairs(cyclesets) do clamp_last_idx(pname) end
end

------------------------------------------------------------
-- Auto-Prune (when OBS scenes change)
------------------------------------------------------------
local function auto_prune_cyclesets()
    local present = {}
    local current = list_current_scene_names_sorted()
    for _, nm in ipairs(current) do present[nm] = true end
    -- If OBS hasn't populated scenes yet, skip pruning to avoid wiping sets
    if #current == 0 then return end
    for pname, list in pairs(cyclesets) do
        local kept = {}
        for _, nm in ipairs(list) do
            if present[nm] then table.insert(kept, nm) end
        end
        cyclesets[pname] = kept
        clamp_last_idx(pname)
    end
end

------------------------------------------------------------
-- Hotkeys: per-CycleSetSceneList registration / cleanup / migration
------------------------------------------------------------
local function unregister_hotkey_if_supported(id)
    if id and obs.obs_hotkey_unregister then
        obs.obs_hotkey_unregister(id)
    end
end

local function delete_cycleset_hotkeys(pname)
    -- Unregister live hotkey IDs and remove saved bindings for the cycleset
    local ids = hotkey_ids_by_cycleset[pname]
    if ids then
        unregister_hotkey_if_supported(ids.next_id)
        unregister_hotkey_if_supported(ids.prev_id)
        hotkey_ids_by_cycleset[pname] = nil
        hotkey_callbacks_by_cycleset[pname] = nil
    end
    if last_settings then
        obs.obs_data_erase(last_settings, settings_key_for_binding(pname, "next"))
        obs.obs_data_erase(last_settings, settings_key_for_binding(pname, "prev"))
    end
end

local function register_cycleset_hotkeys(pname, load_from_settings)
    -- Create callbacks bound to cycleset name
    local function on_next(pressed) if pressed then cycle_next_for(pname) end end
    local function on_prev(pressed) if pressed then cycle_prev_for(pname) end end

    local an_next = "cycle_cycleset_next::" .. slug(pname)
    local an_prev = "cycle_cycleset_prev::" .. slug(pname)
    local label_next = ("CycleSets (Set: %s): Next"):format(pname)
    local label_prev = ("CycleSets (Set: %s): Previous"):format(pname)

    local next_id = obs.obs_hotkey_register_frontend(an_next, label_next, on_next)
    local prev_id = obs.obs_hotkey_register_frontend(an_prev, label_prev, on_prev)

    hotkey_ids_by_cycleset[pname] = { next_id = next_id, prev_id = prev_id }
    hotkey_callbacks_by_cycleset[pname] = { next_cb = on_next, prev_cb = on_prev }

    if load_from_settings and last_settings then
        local arrn = obs.obs_data_get_array(last_settings, settings_key_for_binding(pname, "next"))
        if arrn ~= nil then obs.obs_hotkey_load(next_id, arrn); obs.obs_data_array_release(arrn) end
        local arrp = obs.obs_data_get_array(last_settings, settings_key_for_binding(pname, "prev"))
        if arrp ~= nil then obs.obs_hotkey_load(prev_id, arrp); obs.obs_data_array_release(arrp) end
    end
end

-- Remove IDs and delete saved bindings for cycleset
-- delete_cycleset_hotkeys is defined earlier during previous patch

-- Save old bindings, unregister old IDs, register new with same bindings
local function migrate_cycleset_hotkeys(old_name, new_name)
    local saved_next, saved_prev = nil, nil
    -- If IDs exist, pull live bindings
    local ids = hotkey_ids_by_cycleset[old_name]
    if ids then
        saved_next = obs.obs_hotkey_save(ids.next_id)
        saved_prev = obs.obs_hotkey_save(ids.prev_id)
        unregister_hotkey_if_supported(ids.next_id)
        unregister_hotkey_if_supported(ids.prev_id)
        hotkey_ids_by_cycleset[old_name] = nil
        hotkey_callbacks_by_cycleset[old_name] = nil
    else
        -- else get from settings keys
        if last_settings then
            saved_next = obs.obs_data_get_array(last_settings, settings_key_for_binding(old_name, "next"))
            saved_prev = obs.obs_data_get_array(last_settings, settings_key_for_binding(old_name, "prev"))
        end
    end

    -- Register new IDs
    register_cycleset_hotkeys(new_name, false)

    -- Load saved bindings into new IDs and store under new keys
    if last_settings then
        if saved_next then
            obs.obs_hotkey_load(hotkey_ids_by_cycleset[new_name].next_id, saved_next)
            obs.obs_data_set_array(last_settings, settings_key_for_binding(new_name, "next"), saved_next)
            obs.obs_data_array_release(saved_next)
        else
            obs.obs_data_erase(last_settings, settings_key_for_binding(new_name, "next"))
        end
        if saved_prev then
            obs.obs_hotkey_load(hotkey_ids_by_cycleset[new_name].prev_id, saved_prev)
            obs.obs_data_set_array(last_settings, settings_key_for_binding(new_name, "prev"), saved_prev)
            obs.obs_data_array_release(saved_prev)
        else
            obs.obs_data_erase(last_settings, settings_key_for_binding(new_name, "prev"))
        end
        -- Remove old keys
        obs.obs_data_erase(last_settings, settings_key_for_binding(old_name, "next"))
        obs.obs_data_erase(last_settings, settings_key_for_binding(old_name, "prev"))
    end
end

------------------------------------------------------------
-- UI (Properties)
------------------------------------------------------------
local PROP_CYCLESET      = "cycleset_select"
local PROP_NEWNAME_CYCLESET      = "new_cycleset_name"
local PROP_AVAIL        = "available_scene"
local PROP_CYCLESET_LIST = "cycleset_scene_select"
local PROP_TAP_WINDOW   = "tap_window_ms"

local function props_get(props, id) return obs.obs_properties_get(props, id) end

local function refresh_cycleset_dropdown(props)
    local p = props_get(props, PROP_CYCLESET)
    obs.obs_property_list_clear(p)
    local keys = {}
    for k,_ in pairs(cyclesets) do table.insert(keys, k) end
    table.sort(keys, function(a,b) return string.lower(a) < string.lower(b) end)
    for _, name in ipairs(keys) do
        obs.obs_property_list_add_string(p, name, name)
    end
end

local function rebuild_available_list(props)
    local p = props_get(props, PROP_AVAIL)
    obs.obs_property_list_clear(p)
    obs.obs_property_list_add_string(p, "<Select a scene>", "")
    for _, name in ipairs(list_current_scene_names_sorted()) do
        obs.obs_property_list_add_string(p, name, name)
    end
end

local function rebuild_cycleset_scene_selector(props)
    local p = props and obs.obs_properties_get(props, PROP_CYCLESET_LIST)
    if not p then
        -- If props are not available, we can't rebuild the UI list.
        -- This happens during script_update.
        return
    end
    obs.obs_property_list_clear(p)
    obs.obs_property_list_add_string(p, "<Select from CycleSetSceneList>", "")
    for _, name in ipairs(cyclesets[active_cycleset] or {}) do
        obs.obs_property_list_add_string(p, name, name)
    end
end

-- UI Callbacks
local function cb_cycleset_changed(props, prop, settings)
    local new = obs.obs_data_get_string(settings, PROP_CYCLESET)
    if new and new ~= active_cycleset then
        active_cycleset = new
        rebuild_cycleset_scene_selector(props)
        -- persist active cycleset selection
        persist_now()
    end
    return true
end

local function ui_add_cycleset(props, prop)
    local name = obs.obs_data_get_string(last_settings, PROP_NEWNAME_CYCLESET) or ""
    name = (name:gsub("^%s*(.-)%s*$", "%1"))
    if name == "" or cyclesets[name] then return false end
    cyclesets[name] = {}
    active_cycleset = name
    tap_state_by_cycleset[name] = nil
    obs.obs_data_set_string(last_settings, PROP_CYCLESET, name)
    refresh_cycleset_dropdown(props)
    rebuild_cycleset_scene_selector(props)
    -- Register hotkeys for new cycleset
    register_cycleset_hotkeys(name, true)
    -- Clear the new-name textbox
    if last_settings then obs.obs_data_set_string(last_settings, PROP_NEWNAME_CYCLESET, "") end
    -- Persist cyclesets immediately
    persist_now()
    return true
end

local function ui_rename_cycleset(props, prop)
    local newname = obs.obs_data_get_string(last_settings, PROP_NEWNAME_CYCLESET) or ""
    newname = (newname:gsub("^%s*(.-)%s*$", "%1"))
    if newname == "" or not cyclesets[active_cycleset] or cyclesets[newname] then return false end

    -- Migrate data
    local old = active_cycleset
    cyclesets[newname] = cyclesets[old]
    cyclesets[old] = nil

    last_selected_idx_by_cycleset[newname] = last_selected_idx_by_cycleset[old]
    last_selected_idx_by_cycleset[old] = nil

    tap_state_by_cycleset[newname] = tap_state_by_cycleset[old]
    tap_state_by_cycleset[old] = nil

    -- Hotkey migration
    migrate_cycleset_hotkeys(old, newname)

    active_cycleset = newname
    obs.obs_data_set_string(last_settings, PROP_CYCLESET, newname)
    refresh_cycleset_dropdown(props)
    rebuild_cycleset_scene_selector(props)
    -- Clear the new-name textbox after renaming
    if last_settings then obs.obs_data_set_string(last_settings, PROP_NEWNAME_CYCLESET, "") end
    -- Persist cyclesets immediately
    persist_now()
    return true
end

local function ui_delete_cycleset(props, prop)
    local name = active_cycleset
    if not cyclesets[name] then return false end

    -- Cleanup hotkeys and bindings for this cycleset
    delete_cycleset_hotkeys(name)

    cyclesets[name] = nil
    last_selected_idx_by_cycleset[name] = nil
    tap_state_by_cycleset[name] = nil

    ensure_defaults()
    obs.obs_data_set_string(last_settings, PROP_CYCLESET, active_cycleset)
    refresh_cycleset_dropdown(props)
    rebuild_cycleset_scene_selector(props)
    -- Persist cyclesets immediately
    persist_now()
    return true
end

local function ui_add_selected_scene(props, prop)
    local sel = obs.obs_data_get_string(last_settings, PROP_AVAIL)
    if sel ~= "" then
        local list = cyclesets[active_cycleset] or {}
        if not index_of(list, sel) then table.insert(list, sel) end
        cyclesets[active_cycleset] = list
        rebuild_cycleset_scene_selector(props)
        clamp_last_idx(active_cycleset)
        -- Persist cyclesets immediately
        persist_now()
        return true
    end
    return false
end

local function ui_remove_selected_from_cycleset(props, prop)
    local sel = obs.obs_data_get_string(last_settings, PROP_CYCLESET_LIST)
    if sel ~= "" then
        local list = cyclesets[active_cycleset] or {}
        local idx = index_of(list, sel)
        if idx then table.remove(list, idx) end
        cyclesets[active_cycleset] = list
        rebuild_cycleset_scene_selector(props)
        clamp_last_idx(active_cycleset)
        -- Persist cyclesets immediately
        persist_now()
        return true
    end
    return false
end

local function ui_move_up(props, prop)
    local sel = obs.obs_data_get_string(last_settings, PROP_CYCLESET_LIST)
    local list = cyclesets[active_cycleset] or {}
    local i = index_of(list, sel)
    if not i or i <= 1 then return false end
    list[i], list[i-1] = list[i-1], list[i]
    rebuild_cycleset_scene_selector(props)
    obs.obs_data_set_string(last_settings, PROP_CYCLESET_LIST, sel)
    -- Persist cyclesets immediately
    persist_now()
    return true
end

local function ui_move_down(props, prop)
    local sel = obs.obs_data_get_string(last_settings, PROP_CYCLESET_LIST)
    local list = cyclesets[active_cycleset] or {}
    local i = index_of(list, sel)
    if not i or i >= #list then return false end
    list[i], list[i+1] = list[i+1], list[i]
    rebuild_cycleset_scene_selector(props)
    obs.obs_data_set_string(last_settings, PROP_CYCLESET_LIST, sel)
    -- Persist cyclesets immediately
    persist_now()
    return true
end

------------------------------------------------------------
-- Cycling (multi-tap per CycleSetSceneList)
------------------------------------------------------------
local function commit_last_idx(pname, idx)
    -- Always update in-memory last selected index so multi-tap uses it during the session.
    last_selected_idx_by_cycleset[pname] = idx
end

cycle_next_for = function(pname)
    local list = cyclesets[pname] or {}
    local N = #list
    if N == 0 then return end
    ensure_cycleset_state(pname)
    local ts = tap_state_by_cycleset[pname]
    local now = mono_ms()

    if now > (ts.next_deadline or 0) or not ts.active_idx_next then
        local idx = last_selected_idx_by_cycleset[pname] or 1
        idx = clamp(idx, 1, N)
        ts.active_idx_next = idx
        set_scene_by_name(list[ts.active_idx_next])
        ts.next_deadline = now + tap_window_ms
        commit_last_idx(pname, ts.active_idx_next)
        return
    else
        ts.active_idx_next = (ts.active_idx_next % N) + 1
        set_scene_by_name(list[ts.active_idx_next])
        ts.next_deadline = now + tap_window_ms
        commit_last_idx(pname, ts.active_idx_next)
    end
end

cycle_prev_for = function(pname)
    local list = cyclesets[pname] or {}
    local N = #list
    if N == 0 then return end
    ensure_cycleset_state(pname)
    local ts = tap_state_by_cycleset[pname]
    local now = mono_ms()

    if now > (ts.prev_deadline or 0) or not ts.active_idx_prev then
        local idx = last_selected_idx_by_cycleset[pname] or 1
        idx = clamp(idx, 1, N)
        ts.active_idx_prev = idx
        set_scene_by_name(list[ts.active_idx_prev])
        ts.prev_deadline = now + tap_window_ms
        commit_last_idx(pname, ts.active_idx_prev)
        return
    else
        ts.active_idx_prev = ((ts.active_idx_prev + N - 2) % N) + 1
        set_scene_by_name(list[ts.active_idx_prev])
        ts.prev_deadline = now + tap_window_ms
        commit_last_idx(pname, ts.active_idx_prev)
    end
end

------------------------------------------------------------
-- OBS Script Interface
------------------------------------------------------------
function script_description()
    return [[CycleSets for OBS
Define CycleSetSceneLists (ordered scene lists) and cycle them with per-CycleSetSceneList, multi-tap hotkeys.

Usage:
1) Create/select an Active CycleSetSceneList.
2) Add scenes from "Available Scenes" to the CycleSetSceneList.
3) Reorder or remove as needed.
4) Bind hotkeys in Settings → Hotkeys:
    - "CycleSets (Set: <Name>): Next"
    - "CycleSets (Set: <Name>): Previous"
Press once to recall last selected. Press again within the Tap Window to advance.]]
end

function script_properties()
    local props = obs.obs_properties_create()
    last_props = props

    -- CycleSetSceneList management
    local p = obs.obs_properties_add_list(props, PROP_CYCLESET, "Active CycleSetSceneList",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_set_modified_callback(p, cb_cycleset_changed)

    obs.obs_properties_add_text(props, PROP_NEWNAME_CYCLESET, "New/Rename CycleSetSceneList Name", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_button(props, "btn_add_cycleset", "Add CycleSetSceneList", ui_add_cycleset)
    obs.obs_properties_add_button(props, "btn_rename_cycleset", "Rename Active CycleSetSceneList → New Name", ui_rename_cycleset)
    obs.obs_properties_add_button(props, "btn_delete_cycleset", "Delete Active CycleSetSceneList", ui_delete_cycleset)

    -- Available scenes + add
    obs.obs_properties_add_list(props, PROP_AVAIL, "Available Scenes",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_properties_add_button(props, "btn_add_scene", "Add Selected Scene → CycleSetSceneList", ui_add_selected_scene)

    -- CycleSetSceneList contents and order controls
    obs.obs_properties_add_list(props, PROP_CYCLESET_LIST, "Scenes in Active CycleSetSceneList",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_properties_add_button(props, "btn_move_up", "Move Up", ui_move_up)
    obs.obs_properties_add_button(props, "btn_move_down", "Move Down", ui_move_down)
    obs.obs_properties_add_button(props, "btn_remove_scene", "Remove Selected From CycleSetSceneList", ui_remove_selected_from_cycleset)

    -- Multi-tap settings
    obs.obs_properties_add_int(props, PROP_TAP_WINDOW, "Tap Window (ms)", 150, 2000, 10)

    -- Initial fill
    refresh_cycleset_dropdown(props)
    rebuild_available_list(props)
    rebuild_cycleset_scene_selector(props)
    -- Ensure the cycleset dropdown shows the current active cycleset
    if last_settings then
        obs.obs_data_set_string(last_settings, PROP_CYCLESET, active_cycleset)
    end
    return props
end

function script_update(settings)
    last_settings = settings
    -- detect if the active cycleset was changed via the UI dropdown
    local new_cycleset = obs.obs_data_get_string(settings, PROP_CYCLESET) or active_cycleset
    if new_cycleset ~= active_cycleset then
        active_cycleset = new_cycleset
        -- refresh UI lists if we have the props object
        if last_props then
            refresh_cycleset_dropdown(last_props)
            rebuild_cycleset_scene_selector(last_props)
        end
        -- update saved selection for the scenes-in-cycleset list so the UI reflects the new active cycleset
        if last_settings then
            local sel_scene = nil
            local idx = last_selected_idx_by_cycleset[active_cycleset]
            if idx and cyclesets[active_cycleset] and cyclesets[active_cycleset][idx] then
                sel_scene = cyclesets[active_cycleset][idx]
            end
            if sel_scene then
                obs.obs_data_set_string(last_settings, PROP_CYCLESET_LIST, sel_scene)
            else
                obs.obs_data_set_string(last_settings, PROP_CYCLESET_LIST, "")
            end
            -- Also update saved active cycleset value
            obs.obs_data_set_string(last_settings, PROP_CYCLESET, active_cycleset)
        end
    end

    -- sync scalar settings
    local tw = obs.obs_data_get_int(settings, PROP_TAP_WINDOW)
    if tw and tw > 0 then tap_window_ms = tw end
    -- (Per-cycleset last-selected indices are restored during load_cyclesets_from_settings)
end

function script_load(settings)
    last_settings = settings
    load_cyclesets_from_settings(settings)
    auto_prune_cyclesets()

    -- React to OBS frontend events to keep cyclesets in sync with scenes
    obs.obs_frontend_add_event_callback(function(ev)
        if ev == obs.OBS_FRONTEND_EVENT_SCENE_LIST_CHANGED or ev == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED then
            -- Prune deleted/renamed scenes from all cyclesets, refresh UI and persist
            auto_prune_cyclesets()
            if last_props then
                rebuild_available_list(last_props)
                rebuild_cycleset_scene_selector(last_props)
            end
            persist_now()
        end
    end)

    -- register hotkeys for all cyclesets (and load bindings)
    for pname,_ in pairs(cyclesets) do
        register_cycleset_hotkeys(pname, true)
    end
end

function script_save(settings)
    -- persist everything (including current hotkey bindings)
    save_cyclesets_to_settings(settings)
end
