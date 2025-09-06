------------------------------------------------------------
-- CycleSets for OBS
-- Version: 1.0.0
-- Author: Matthew Chng
--
-- Description:
--   Define multiple profiles, each an ordered list of scenes,
--   and cycle through them with per-profile, multi-tap hotkeys.
--
-- Features:
--   • UI-driven scene selection (no typing names).
--   • Multiple profiles (Add/Rename/Delete).
--   • Per-profile hotkeys (Next/Previous).
--   • Hotkeys removed if profile is deleted; migrated on rename.
--   • Multi-tap: first press = last selected; taps within window advance.
--   • Auto-pruning when OBS scenes are deleted or collections change.
--   • Persistence for profiles, hotkeys, and last selected indices.
--
-- Environment: OBS Studio 28+ (Windows/macOS/Linux), Lua 5.2
------------------------------------------------------------

obs = obslua

------------------------------------------------------------
-- State
------------------------------------------------------------
local profiles = {}                     -- map<string profile, list<string scene_name>>
local active_profile = "Default"

local tap_window_ms = 600               -- configurable
local persist_last_selected = true      -- configurable

-- Last selected scene index per profile (persisted)
local last_selected_idx_by_profile = {} -- map<string,int>

-- Tap state per profile (transient)
local tap_state = {}                    -- map<string,{next_deadline,prev_deadline,active_idx_next,active_idx_prev}>

-- Per-profile hotkeys (transient IDs and callbacks)
local hotkey_ids_by_profile = {}        -- map<string,{next_id,prev_id}>
local hotkey_callbacks_by_profile = {}  -- map<string,{next_cb,prev_cb}>

-- We keep bindings in settings (persisted) under keys per profile.
-- We'll assemble keys as: "hotkey_bindings::<profile>::next"/"prev"

-- Remember last obs settings reference (used by UI callbacks)
local last_settings = nil

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

local function ensure_profile_state(pname)
    tap_state[pname] = tap_state[pname] or {
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

local function set_scene_by_name(name)
    if not name or name == "" then return end
    local src = obs.obs_get_source_by_name(name)
    if src ~= nil then
        obs.obs_frontend_set_current_scene(src)
        obs.obs_source_release(src)
    end
end

local function index_of(list, value)
    for i, v in ipairs(list) do if v == value then return i end end
    return nil
end

local function ensure_defaults()
    if next(profiles) == nil then
        profiles["Default"] = {}
        active_profile = "Default"
    end
    if not profiles[active_profile] then
        for k,_ in pairs(profiles) do active_profile = k; break end
    end
end

local function clamp_last_idx(pname)
    local N = #(profiles[pname] or {})
    if N == 0 then
        last_selected_idx_by_profile[pname] = nil
        return
    end
    local cur = last_selected_idx_by_profile[pname] or 1
    last_selected_idx_by_profile[pname] = clamp(cur, 1, N)
end

------------------------------------------------------------
-- Persistence (profiles, last-selected, hotkeys, settings)
------------------------------------------------------------
local function settings_key_for_binding(profile, which)
    -- which = "next" | "prev"
    return "hotkey_bindings::" .. profile .. "::" .. which
end

local function save_profiles_to_settings(settings)
    -- profiles
    local arr = obs.obs_data_array_create()
    for name, scenes in pairs(profiles) do
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
    obs.obs_data_set_array(settings, "profiles", arr)
    obs.obs_data_array_release(arr)

    -- active profile
    obs.obs_data_set_string(settings, "active_profile", active_profile)

    -- last selected idx per profile
    local lso = obs.obs_data_create()
    for pname, idx in pairs(last_selected_idx_by_profile) do
        obs.obs_data_set_int(lso, pname, idx or 0)
    end
    obs.obs_data_set_obj(settings, "last_selected_idx", lso)
    obs.obs_data_release(lso)

    -- global settings
    obs.obs_data_set_int(settings, "tap_window_ms", tap_window_ms or 600)
    obs.obs_data_set_bool(settings, "persist_last_selected", persist_last_selected)

    -- hotkey bindings (save current IDs to arrays)
    for pname, ids in pairs(hotkey_ids_by_profile) do
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

local function load_profiles_from_settings(settings)
    profiles = {}
    active_profile = obs.obs_data_get_string(settings, "active_profile")
    -- profiles
    local arr = obs.obs_data_get_array(settings, "profiles")
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
            if name and name ~= "" then profiles[name] = scenes end
            obs.obs_data_release(obj)
        end
        obs.obs_data_array_release(arr)
    end

    ensure_defaults()

    -- last selected indices
    last_selected_idx_by_profile = {}
    local lso = obs.obs_data_get_obj(settings, "last_selected_idx")
    if lso ~= nil then
        for pname,_ in pairs(profiles) do
            local v = obs.obs_data_get_int(lso, pname)
            if v and v > 0 then last_selected_idx_by_profile[pname] = v end
        end
        obs.obs_data_release(lso)
    end

    -- global settings
    local tw = obs.obs_data_get_int(settings, "tap_window_ms")
    tap_window_ms = (tw and tw > 0) and tw or 600
    persist_last_selected = obs.obs_data_get_bool(settings, "persist_last_selected")
    if persist_last_selected == nil then persist_last_selected = true end

    -- clamp indices
    for pname,_ in pairs(profiles) do clamp_last_idx(pname) end
end

------------------------------------------------------------
-- Auto-Prune (when OBS scenes change)
------------------------------------------------------------
local function auto_prune_profiles()
    local present = {}
    for _, nm in ipairs(list_current_scene_names_sorted()) do present[nm] = true end
    for pname, list in pairs(profiles) do
        local kept = {}
        for _, nm in ipairs(list) do
            if present[nm] then table.insert(kept, nm) end
        end
        profiles[pname] = kept
        clamp_last_idx(pname)
    end
end

------------------------------------------------------------
-- UI (Properties)
------------------------------------------------------------
local PROP_PROFILE      = "profile_select"
local PROP_NEWNAME      = "new_profile_name"
local PROP_AVAIL        = "available_scene"
local PROP_PROFILE_LIST = "profile_scene_select"
local PROP_TAP_WINDOW   = "tap_window_ms"
local PROP_PERSIST_LAST = "persist_last_selected"

local function props_get(props, id) return obs.obs_properties_get(props, id) end

local function refresh_profile_dropdown(props)
    local p = props_get(props, PROP_PROFILE)
    obs.obs_property_list_clear(p)
    local keys = {}
    for k,_ in pairs(profiles) do table.insert(keys, k) end
    table.sort(keys, function(a,b) return string.lower(a) < string.lower(b) end)
    for _, name in ipairs(keys) do
        obs.obs_property_list_add_string(p, name, name)
    end
    obs.obs_property_list_set_string(p, active_profile)
end

local function rebuild_available_list(props)
    local p = props_get(props, PROP_AVAIL)
    obs.obs_property_list_clear(p)
    obs.obs_property_list_add_string(p, "<Select a scene>", "")
    for _, name in ipairs(list_current_scene_names_sorted()) do
        obs.obs_property_list_add_string(p, name, name)
    end
    obs.obs_property_list_set_string(p, "")
end

local function rebuild_profile_scene_selector(props)
    local p = props_get(props, PROP_PROFILE_LIST)
    obs.obs_property_list_clear(p)
    obs.obs_property_list_add_string(p, "<Select from profile>", "")
    for _, name in ipairs(profiles[active_profile] or {}) do
        obs.obs_property_list_add_string(p, name, name)
    end
    obs.obs_property_list_set_string(p, "")
end

-- UI Callbacks
local function cb_profile_changed(props, prop, settings)
    active_profile = obs.obs_data_get_string(settings, PROP_PROFILE)
    rebuild_profile_scene_selector(props)
    return true
end

local function ui_add_profile(props, prop)
    local name = obs.obs_data_get_string(last_settings, PROP_NEWNAME) or ""
    name = (name:gsub("^%s*(.-)%s*$", "%1"))
    if name == "" or profiles[name] then return false end
    profiles[name] = {}
    active_profile = name
    tap_state[name] = nil
    obs.obs_data_set_string(last_settings, PROP_PROFILE, name)
    refresh_profile_dropdown(props)
    rebuild_profile_scene_selector(props)
    -- Register hotkeys for new profile
    register_profile_hotkeys(name, true) -- forward declare; defined later
    return true
end

local function ui_rename_profile(props, prop)
    local newname = obs.obs_data_get_string(last_settings, PROP_NEWNAME) or ""
    newname = (newname:gsub("^%s*(.-)%s*$", "%1"))
    if newname == "" or not profiles[active_profile] or profiles[newname] then return false end

    -- Migrate data
    local old = active_profile
    profiles[newname] = profiles[old]
    profiles[old] = nil

    last_selected_idx_by_profile[newname] = last_selected_idx_by_profile[old]
    last_selected_idx_by_profile[old] = nil

    tap_state[newname] = tap_state[old]
    tap_state[old] = nil

    -- Hotkey migration
    migrate_profile_hotkeys(old, newname) -- forward declare; defined later

    active_profile = newname
    obs.obs_data_set_string(last_settings, PROP_PROFILE, newname)
    refresh_profile_dropdown(props)
    rebuild_profile_scene_selector(props)
    return true
end

local function ui_delete_profile(props, prop)
    local name = active_profile
    if not profiles[name] then return false end

    -- Cleanup hotkeys and bindings for this profile
    delete_profile_hotkeys(name) -- forward declare; defined later

    profiles[name] = nil
    last_selected_idx_by_profile[name] = nil
    tap_state[name] = nil

    ensure_defaults()
    obs.obs_data_set_string(last_settings, PROP_PROFILE, active_profile)
    refresh_profile_dropdown(props)
    rebuild_profile_scene_selector(props)
    return true
end

local function ui_add_selected_scene(props, prop)
    local sel = obs.obs_data_get_string(last_settings, PROP_AVAIL)
    if sel ~= "" then
        local list = profiles[active_profile] or {}
        if not index_of(list, sel) then table.insert(list, sel) end
        profiles[active_profile] = list
        rebuild_profile_scene_selector(props)
        clamp_last_idx(active_profile)
        return true
    end
    return false
end

local function ui_remove_selected_from_profile(props, prop)
    local sel = obs.obs_data_get_string(last_settings, PROP_PROFILE_LIST)
    if sel ~= "" then
        local list = profiles[active_profile] or {}
        local idx = index_of(list, sel)
        if idx then table.remove(list, idx) end
        profiles[active_profile] = list
        rebuild_profile_scene_selector(props)
        clamp_last_idx(active_profile)
        return true
    end
    return false
end

local function ui_move_up(props, prop)
    local sel = obs.obs_data_get_string(last_settings, PROP_PROFILE_LIST)
    local list = profiles[active_profile] or {}
    local i = index_of(list, sel)
    if not i or i <= 1 then return false end
    list[i], list[i-1] = list[i-1], list[i]
    rebuild_profile_scene_selector(props)
    obs.obs_property_list_set_string(props_get(props, PROP_PROFILE_LIST), sel)
    return true
end

local function ui_move_down(props, prop)
    local sel = obs.obs_data_get_string(last_settings, PROP_PROFILE_LIST)
    local list = profiles[active_profile] or {}
    local i = index_of(list, sel)
    if not i or i >= #list then return false end
    list[i], list[i+1] = list[i+1], list[i]
    rebuild_profile_scene_selector(props)
    obs.obs_property_list_set_string(props_get(props, PROP_PROFILE_LIST), sel)
    return true
end

------------------------------------------------------------
-- Cycling (multi-tap per profile)
------------------------------------------------------------
local function commit_last_idx(pname, idx)
    if not persist_last_selected then return end
    last_selected_idx_by_profile[pname] = idx
end

local function cycle_next_for(pname)
    local list = profiles[pname] or {}
    local N = #list
    if N == 0 then return end
    ensure_profile_state(pname)
    local ts = tap_state[pname]
    local now = mono_ms()

    if now > (ts.next_deadline or 0) or not ts.active_idx_next then
        local idx = last_selected_idx_by_profile[pname] or 1
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

local function cycle_prev_for(pname)
    local list = profiles[pname] or {}
    local N = #list
    if N == 0 then return end
    ensure_profile_state(pname)
    local ts = tap_state[pname]
    local now = mono_ms()

    if now > (ts.prev_deadline or 0) or not ts.active_idx_prev then
        local idx = last_selected_idx_by_profile[pname] or 1
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
-- Hotkeys: per-profile registration / cleanup / migration
------------------------------------------------------------
local function unregister_hotkey_if_supported(id)
    if id and obs.obs_hotkey_unregister then
        obs.obs_hotkey_unregister(id)
    end
end

local function register_profile_hotkeys(pname, load_from_settings)
    -- Create callbacks bound to profile name
    local function on_next(pressed) if pressed then cycle_next_for(pname) end end
    local function on_prev(pressed) if pressed then cycle_prev_for(pname) end end

    local an_next = "cycle_profile_next::" .. slug(pname)
    local an_prev = "cycle_profile_prev::" .. slug(pname)
    local label_next = ("Cycle Scenes (Profile: %s): Next"):format(pname)
    local label_prev = ("Cycle Scenes (Profile: %s): Previous"):format(pname)

    local next_id = obs.obs_hotkey_register_frontend(an_next, label_next, on_next)
    local prev_id = obs.obs_hotkey_register_frontend(an_prev, label_prev, on_prev)

    hotkey_ids_by_profile[pname] = { next_id = next_id, prev_id = prev_id }
    hotkey_callbacks_by_profile[pname] = { next_cb = on_next, prev_cb = on_prev }

    if load_from_settings and last_settings then
        local arrn = obs.obs_data_get_array(last_settings, settings_key_for_binding(pname, "next"))
        if arrn ~= nil then obs.obs_hotkey_load(next_id, arrn); obs.obs_data_array_release(arrn) end
        local arrp = obs.obs_data_get_array(last_settings, settings_key_for_binding(pname, "prev"))
        if arrp ~= nil then obs.obs_hotkey_load(prev_id, arrp); obs.obs_data_array_release(arrp) end
    end
end

-- Remove IDs and delete saved bindings for profile
function delete_profile_hotkeys(pname)
    local ids = hotkey_ids_by_profile[pname]
    if ids then
        unregister_hotkey_if_supported(ids.next_id)
        unregister_hotkey_if_supported(ids.prev_id)
    end
    hotkey_ids_by_profile[pname] = nil
    hotkey_callbacks_by_profile[pname] = nil

    if last_settings then
        obs.obs_data_erase(last_settings, settings_key_for_binding(pname, "next"))
        obs.obs_data_erase(last_settings, settings_key_for_binding(pname, "prev"))
    end
end

-- Save old bindings, unregister old IDs, register new with same bindings
function migrate_profile_hotkeys(old_name, new_name)
    local saved_next, saved_prev = nil, nil
    -- If IDs exist, pull live bindings
    local ids = hotkey_ids_by_profile[old_name]
    if ids then
        saved_next = obs.obs_hotkey_save(ids.next_id)
        saved_prev = obs.obs_hotkey_save(ids.prev_id)
        unregister_hotkey_if_supported(ids.next_id)
        unregister_hotkey_if_supported(ids.prev_id)
        hotkey_ids_by_profile[old_name] = nil
        hotkey_callbacks_by_profile[old_name] = nil
    else
        -- else get from settings keys
        if last_settings then
            saved_next = obs.obs_data_get_array(last_settings, settings_key_for_binding(old_name, "next"))
            saved_prev = obs.obs_data_get_array(last_settings, settings_key_for_binding(old_name, "prev"))
        end
    end

    -- Register new IDs
    register_profile_hotkeys(new_name, false)

    -- Load saved bindings into new IDs and store under new keys
    if last_settings then
        if saved_next then
            obs.obs_hotkey_load(hotkey_ids_by_profile[new_name].next_id, saved_next)
            obs.obs_data_set_array(last_settings, settings_key_for_binding(new_name, "next"), saved_next)
            obs.obs_data_array_release(saved_next)
        else
            obs.obs_data_erase(last_settings, settings_key_for_binding(new_name, "next"))
        end
        if saved_prev then
            obs.obs_hotkey_load(hotkey_ids_by_profile[new_name].prev_id, saved_prev)
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
-- OBS Script Interface
------------------------------------------------------------
function script_description()
    return [[CycleSets for OBS
Define profiles (ordered scene lists) and cycle them with per-profile, multi-tap hotkeys.

Usage:
1) Create/select an Active Profile.
2) Add scenes from "Available Scenes" to the profile.
3) Reorder or remove as needed.
4) Bind hotkeys in Settings → Hotkeys:
   - "Cycle Scenes (Profile: <Name>): Next"
   - "Cycle Scenes (Profile: <Name>): Previous"
Press once to recall last selected. Press again within the Tap Window to advance.]]
end

function script_properties()
    local props = obs.obs_properties_create()

    -- Profile management
    local p = obs.obs_properties_add_list(props, PROP_PROFILE, "Active Profile",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_set_modified_callback(p, cb_profile_changed)

    obs.obs_properties_add_text(props, PROP_NEWNAME, "New/Rename Profile Name", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_button(props, "btn_add_profile", "Add Profile", ui_add_profile)
    obs.obs_properties_add_button(props, "btn_rename_profile", "Rename Active → New Name", ui_rename_profile)
    obs.obs_properties_add_button(props, "btn_delete_profile", "Delete Active Profile", ui_delete_profile)

    -- Available scenes + add
    obs.obs_properties_add_list(props, PROP_AVAIL, "Available Scenes",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_properties_add_button(props, "btn_add_scene", "Add Selected Scene → Profile", ui_add_selected_scene)

    -- Profile contents and order controls
    obs.obs_properties_add_list(props, PROP_PROFILE_LIST, "Scenes in Active Profile",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_properties_add_button(props, "btn_move_up", "Move Up", ui_move_up)
    obs.obs_properties_add_button(props, "btn_move_down", "Move Down", ui_move_down)
    obs.obs_properties_add_button(props, "btn_remove_scene", "Remove Selected From Profile", ui_remove_selected_from_profile)

    -- Multi-tap settings
    obs.obs_properties_add_int(props, PROP_TAP_WINDOW, "Tap Window (ms)", 150, 2000, 10)
    obs.obs_properties_add_bool(props, PROP_PERSIST_LAST, "Persist Last Selected")

    -- Initial fill
    refresh_profile_dropdown(props)
    rebuild_available_list(props)
    rebuild_profile_scene_selector(props)
    return props
end

function script_update(settings)
    last_settings = settings
    -- sync scalar settings
    local tw = obs.obs_data_get_int(settings, PROP_TAP_WINDOW)
    if tw and tw > 0 then tap_window_ms = tw end
    local pls = obs.obs_data_get_bool(settings, PROP_PERSIST_LAST)
    if pls ~= nil then persist_last_selected = pls end

    -- Keep dropdown in sync
    obs.obs_data_set_string(settings, PROP_PROFILE, active_profile)
end

function script_load(settings)
    last_settings = settings
    load_profiles_from_settings(settings)
    auto_prune_profiles()

    -- register hotkeys for all profiles (and load bindings)
    for pname,_ in pairs(profiles) do
        register_profile_hotkeys(pname, true)
    end

    -- Listen for scene list changes → auto-prune & refresh UI lists
    obs.obs_frontend_add_event_callback(function(event)
        if event == obs.OBS_FRONTEND_EVENT_SCENE_LIST_CHANGED
           or event == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED
           or event == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CLEANUP then
            auto_prune_profiles()
            -- Clamp and reset tap_state if needed
            for pname,_ in pairs(profiles) do clamp_last_idx(pname) end
            -- Try to refresh UI (if scripts window open)
            if last_settings then
                -- Nudge available/profile lists by re-setting selections
                -- (Properties refresh is driven by OBS; this keeps values coherent)
            end
        end
    end)
end

function script_save(settings)
    -- persist everything (including current hotkey bindings)
    save_profiles_to_settings(settings)
end