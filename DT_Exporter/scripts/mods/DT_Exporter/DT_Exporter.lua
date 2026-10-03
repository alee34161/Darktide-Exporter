-- DT_Exporter
-- Standalone Darktide stat exporter. No Power_DI dependency.
-- Hooks the same game classes PDI uses directly, producing the same
-- JSON output format as the original PDI_Exporter.

local mod = get_mod("DT_Exporter")

-- ── JSON serialiser ────────────────────────────────────────────────────────

local function tojson(v)
    local t = type(v)
    if t == "nil"     then return "null" end
    if t == "boolean" then return tostring(v) end
    if t == "number"  then return tostring(v) end
    if t == "string"  then
        v = v:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r')
        return '"'..v..'"'
    end
    if t == "table" then
        local n = #v
        local is_arr = n > 0
        if is_arr then
            for k in pairs(v) do
                if type(k) ~= "number" then is_arr = false; break end
            end
        end
        if is_arr then
            local parts = {}
            for i = 1, n do parts[i] = tojson(v[i]) end
            return "["..table.concat(parts,",").."]"
        else
            local parts = {}
            for k, val in pairs(v) do
                table.insert(parts, tojson(tostring(k))..":"..tojson(val))
            end
            return "{"..table.concat(parts,",").."}"
        end
    end
    return "null"
end

-- ── File writing ───────────────────────────────────────────────────────────

local function save_json(data)
    local now = os.date("*t")
    local fname = string.format(
        "pdi_%04d-%02d-%02d_%02d-%02d-%02d",
        now.year, now.month, now.day, now.hour, now.min, now.sec)

    local DMF = get_mod("DMF")
    if DMF and DMF.dtf then
        DMF:dtf(data, fname, 10)
        mod:echo("DT Exporter: Saved -> binaries\\dump\\"..fname..".json")
    else
        mod:echo("DT Exporter: ERROR - DMF:dtf not available")
    end
end

-- ── Unknown-enemy log ──────────────────────────────────────────────────────
-- One file per mission that had unrecognised enemies, written next to the
-- JSON exports in binaries/dump. The "zz_" prefix sorts these above the
-- pdi_ exports when the folder is sorted by name, newest first. Delete each
-- file once its enemies are added to the breed tables.

local function log_unknown_breeds(unknown, date_str, time_str)
    local now  = os.date("*t")
    local path = string.format(
        "dump/zz_UNKNOWN_ENEMIES_%04d-%02d-%02d_%02d-%02d-%02d.log",
        now.year, now.month, now.day, now.hour, now.min, now.sec)
    local ok, err = pcall(function()
        local f = Mods.lua.io.open(path, "w")
        if not f then error("could not open "..path) end
        f:write("Unrecognised enemies - mission started "..date_str.." "..time_str.."\n")
        f:write("Add each to a breed table at the top of DT_Exporter.lua.\n\n")
        for breed, hits in pairs(unknown) do
            f:write(string.format("%s  (%d hits)\n", breed, hits))
        end
        f:close()
    end)
    if not ok then
        mod:echo("DT Exporter: could not write unknown-enemy log: "..tostring(err))
    end
    return ok
end

-- ── UUID helper ────────────────────────────────────────────────────────────
-- Must match utilities.get_address / utilities.get_unit_uuid for game objects.
-- For non-level units (players, enemies) both PDI functions return this format.

local function unit_uuid(unit)
    if not unit then return nil end
    return "u_"..string.format("%p", unit)
end

-- ── Breed tables ───────────────────────────────────────────────────────────
-- Update these after patches that add new enemy types.
-- Source of truth: PDI minion_categories.lua

local MELEE_ELITE = {
    chaos_ogryn_bulwark  = true,  -- Crusher
    chaos_ogryn_executor = true,  -- Mauler variant
    cultist_berzerker    = true,  -- Rager
    renegade_berzerker   = true,  -- Rager variant
    renegade_executor    = true,  -- Mauler
}
local RANGED_ELITE = {
    chaos_ogryn_gunner      = true,  -- Reaper
    cultist_gunner          = true,  -- Gunner
    cultist_shocktrooper    = true,  -- Gunner variant
    renegade_gunner         = true,  -- Gunner
    renegade_plasma_gunner  = true,  -- Plasma Gunner
    renegade_radio_operator = true,  -- Radio Operator
    renegade_shocktrooper   = true,  -- Shocktrooper
}
local MELEE_SPEC = {
    chaos_armored_hound    = true,  -- Armored Hound
    chaos_hound            = true,  -- Hound
    chaos_hound_mutator    = true,  -- Hound variant
    chaos_poxwalker_bomber = true,  -- Burster
    cultist_flamer         = true,  -- Flamer
    cultist_grenadier      = true,  -- Bomber
    cultist_mutant         = true,  -- Mutant
    cultist_mutant_mutator = true,  -- Mutant variant
    renegade_flamer        = true,  -- Flamer
    renegade_netgunner     = true,  -- Trapper
}
local RANGED_SPEC = {
    renegade_grenadier = true,  -- Bomber
    renegade_sniper    = true,  -- Sniper
}
local HORDE_TRASH = {
    chaos_armored_infected          = true,
    chaos_lesser_mutated_poxwalker  = true,
    chaos_mutated_poxwalker         = true,
    chaos_newly_infected            = true,
    chaos_poxwalker                 = true,
    cultist_melee                   = true,  -- Bruiser
    cultist_ritualist               = true,
    renegade_melee                  = true,  -- Bruiser
    cultist_vanguard                = true,  -- Shield
    renegade_vanguard               = true,  -- Shield
}
local RANGED_TRASH = {
    cultist_assault   = true,  -- Stalker
    renegade_assault  = true,  -- Stalker
    renegade_rifleman = true,  -- Shooter
}
local BOSS = {
    attack_valkyrie           = true,
    chaos_beast_of_nurgle     = true,
    chaos_daemonhost          = true,
    chaos_ogryn_houndmaster   = true,
    chaos_plague_ogryn        = true,
    chaos_spawn               = true,
    cultist_captain           = true,
    renegade_captain          = true,
    renegade_twin_captain     = true,
    renegade_twin_captain_two = true,
}
local function is_known_breed(b)
    return MELEE_ELITE[b] or RANGED_ELITE[b] or MELEE_SPEC[b] or RANGED_SPEC[b]
        or HORDE_TRASH[b] or RANGED_TRASH[b] or BOSS[b]
end

local AMMO_CACHE = { ammo_cache_deployable=true, ammo_cache_pocketable=true }
local LARGE_CLIP  = { large_clip=true }
local SMALL_CLIP  = { small_clip=true }

-- ── Session data ───────────────────────────────────────────────────────────

local _spawns          = {}   -- [unit_uuid] = { unit_name, max_health }
local _profiles        = {}   -- [unit_uuid] = { archetype, loadout, talents }
local _attacks         = {}   -- array of attack event records
local _abilities       = {}   -- array of ability charge change records
local _interacts       = {}   -- array of interaction event records
local _pstatus         = {}   -- array of { player_unit_uuid } — used to collect player UUIDs
local _active_ixn      = {}   -- cache: interactee_game_object_id -> interactor_unit
local _ability_charges = {}   -- cache: "ability_type_uuid" -> last known num_charges
local _psyker_actions  = {}   -- cache: uuid -> last weapon action name (smite/chain-lightning)
local _start_time      = nil
local _havoc           = nil   -- parsed Havoc data, nil for non-Havoc missions

local function reset_data()
    _spawns          = {}
    _profiles        = {}
    _attacks         = {}
    _abilities       = {}
    _interacts       = {}
    _pstatus         = {}
    _active_ixn      = {}
    _ability_charges = {}
    _psyker_actions  = {}
    _start_time      = nil
    _havoc           = nil
end

-- Snapshot of the last completed mission. reset_data() assigns fresh tables,
-- so the references held here survive the hub transition intact.
local _last_mission = nil

local function snapshot()
    return {
        spawns     = _spawns,
        profiles   = _profiles,
        attacks    = _attacks,
        abilities  = _abilities,
        interacts  = _interacts,
        pstatus    = _pstatus,
        start_time = _start_time,
        havoc      = _havoc,
    }
end

local function in_mission()
    local ok, res = pcall(function()
        local gm = Managers.state.game_mode
        return gm ~= nil and gm:game_mode_name() ~= "hub"
    end)
    return ok and res
end

-- ── Hooks ──────────────────────────────────────────────────────────────────

-- Talent values: pre-1.13.0 a plain tier number; 1.13.0+ a table
-- { tier = N, node_name = ..., target_slot = ... }. Normalise to the tier.
-- Havoc rank/theme/faction/circumstances/modifiers. Managers.state.difficulty
-- parses this on every client during gameplay init (see
-- game_mode_extension_havoc.lua). Returns nil outside Havoc missions.
local function capture_havoc()
    local ok, data = pcall(function()
        local diff = Managers.state.difficulty
        return diff and diff.get_parsed_havoc_data and diff:get_parsed_havoc_data()
    end)
    if not ok or type(data) ~= "table" then return nil end

    local circumstances = {}
    for i, c in ipairs(data.circumstances or {}) do circumstances[i] = tostring(c) end

    local modifiers = {}
    for i, m in ipairs(data.modifiers or {}) do
        modifiers[i] = { name = tostring(m.name), level = tonumber(m.level) or 0 }
    end

    return {
        rank          = data.havoc_rank,
        theme         = data.theme,
        faction       = data.faction,
        mission       = data.mission,
        circumstances = circumstances,
        modifiers     = modifiers,
    }
end

local function copy_talents(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do
        local tier
        if type(v) == "number" then
            tier = v
        elseif type(v) == "table" then
            tier = tonumber(v.tier) or 1
        end
        if tier and tier > 0 then out[tostring(k)] = tier end
    end
    return out
end

-- No existence check here: many game classes load after this mod, and DMF
-- defers the hook until they exist. DMF prints its own error for real misses.
local function safe_hook(class_name, method_name, fn)
    local ok, err = pcall(function()
        mod:hook_safe(CLASS[class_name], method_name, fn)
    end)
    if not ok then
        mod:echo("DT Exporter: hook failed ["..class_name.."."..method_name.."]: "..tostring(err))
    end
end

-- 1. UnitSpawnerManager._add_network_unit
--    Mirrors PDI's add_network_unit exactly:
--    - Builds UUID→name map (breed names for enemies, display names for players)
--    - Captures max_health for accurate kill-damage formula
--    - Copies player profiles (archetype, loadout, talents) — PDI's PlayerProfiles
--      datasource has no hook_templates; it is populated inline here
safe_hook("UnitSpawnerManager", "_add_network_unit",
    function(self, unit, game_object_id, is_husk)
        local uuid = unit_uuid(unit)
        if not uuid then return end

        local ok, err = pcall(function()
            local go_field     = GameSession.game_object_field
            local has_go_field = GameSession.has_game_object_field
            local gs           = Managers.state.game_session:game_session()
            local template_id  = go_field(gs, game_object_id, "unit_template")
            local template_name = self._unit_template_network_lookup
                and self._unit_template_network_lookup[template_id]

            local unit_name, max_health

            if template_name == "player_character" then
                local peer_id  = go_field(gs, game_object_id, "owner_peer_id")
                local local_id = go_field(gs, game_object_id, "local_player_id")
                local player   = peer_id and Managers.player:player(peer_id, local_id)
                if player and player:is_human_controlled() then
                    local profile = player:profile()
                    if profile then
                        unit_name = profile.name
                        _profiles[uuid] = {
                            archetype = profile.archetype,
                            loadout   = profile.loadout,
                            -- Copy now: the live talents table gets cleared
                            -- later, so a reference would be empty at export.
                            talents   = copy_talents(profile.talents),
                        }
                    end
                end
                _pstatus[#_pstatus+1] = { player_unit_uuid = uuid }

            elseif has_go_field(gs, game_object_id, "breed_id") then
                local breed_id = go_field(gs, game_object_id, "breed_id")
                unit_name = NetworkLookup.breed_names[breed_id]

            elseif has_go_field(gs, game_object_id, "pickup_id") then
                local pickup_id = go_field(gs, game_object_id, "pickup_id")
                unit_name = NetworkLookup.pickup_names[pickup_id]
            end

            if has_go_field(gs, game_object_id, "health") then
                max_health = go_field(gs, game_object_id, "health")
            end

            _spawns[uuid] = { unit_name = unit_name, max_health = max_health }

            if not _start_time then
                _start_time = os.time()
                _havoc = capture_havoc()
            end
        end)
        if not ok then
            mod:echo("DT Exporter: _add_network_unit error: "..tostring(err))
        end
    end
)

-- 2. AttackReportManager.add_attack_result
--    Mirrors PDI's add_attack_result: captures attacked_unit_damage_taken
--    from the health extension so the kill-damage formula is accurate.
safe_hook("AttackReportManager", "add_attack_result",
    function(self, damage_profile, attacked_unit, attacking_unit, _dir, _pos,
             hit_weakspot, damage, attack_result, attack_type, _eff, is_crit)
        local health_ext = attacked_unit
            and ScriptUnit.has_extension(attacked_unit, "health_system")
        _attacks[#_attacks+1] = {
            damage_profile_name       = damage_profile and damage_profile.name,
            attacking_unit_uuid       = unit_uuid(attacking_unit),
            attacked_unit_uuid        = unit_uuid(attacked_unit),
            attacked_unit_damage_taken = health_ext and health_ext:damage_taken() or 0,
            hit_weakspot              = hit_weakspot or false,
            damage                    = damage or 0,
            attack_result             = attack_result,
            attack_type               = attack_type,
            is_critical_strike        = is_crit or false,
        }
    end
)

-- 3. InteracteeSystem — revives, rescues, pickups
safe_hook("InteracteeSystem", "rpc_interaction_started",
    function(self, channel_id, unit_id, is_level_unit, interactor_go_id)
        local ok, err = pcall(function()
            local us         = Managers.state.unit_spawner
            local interactor = us:unit(interactor_go_id, false)
            local interactee = us:unit(unit_id, is_level_unit)
            local ext        = self._unit_to_extension_map
                and self._unit_to_extension_map[interactee]
            _active_ixn[unit_id] = interactor
            _interacts[#_interacts+1] = {
                event                = "interaction_started",
                interaction_type     = ext and ext:interaction_type() or nil,
                interactor_unit_uuid = unit_uuid(interactor),
                interactee_unit_uuid = unit_uuid(interactee),
            }
        end)
        if not ok then
            mod:echo("DT Exporter: rpc_interaction_started error: "..tostring(err))
        end
    end
)

safe_hook("InteracteeSystem", "rpc_interaction_stopped",
    function(self, channel_id, unit_id, is_level_unit, _interactor_go_id, result)
        local ok, err = pcall(function()
            local us         = Managers.state.unit_spawner
            local interactee = us:unit(unit_id, is_level_unit)
            local interactor = _active_ixn[unit_id]
            local ext        = self._unit_to_extension_map
                and self._unit_to_extension_map[interactee]
            _active_ixn[unit_id] = nil
            _interacts[#_interacts+1] = {
                event                = "interaction_stopped",
                interaction_type     = ext and ext:interaction_type() or nil,
                interactor_unit_uuid = unit_uuid(interactor),
                interactee_unit_uuid = unit_uuid(interactee),
                result               = NetworkLookup.interaction_result
                    and NetworkLookup.interaction_result[result],
            }
        end)
        if not ok then
            mod:echo("DT Exporter: rpc_interaction_stopped error: "..tostring(err))
        end
    end
)

-- 4. Ability tracking (combat_ability + grenade_ability charge deltas)
local _ability_types = { "combat_ability", "grenade_ability" }

-- Darktide 1.13.0 replaced cooldowns with "ability resources"; reading the old
-- num_charges component field now throws. remaining_ability_charges() is the
-- supported API on both PlayerUnitAbilityExtension and PlayerHuskAbilityExtension.
local function current_charges(self, ability_type)
    if self.remaining_ability_charges then
        return self:remaining_ability_charges(ability_type) or 0
    end
    -- Pre-1.13.0 fallback
    local comps = self._ability_components or self._components
    local comp  = comps and comps[ability_type]
    return comp and comp.num_charges or 0
end

local _ability_error_logged = false

local function track_ability_update(self, unit, dt, t)
    local ok, err = pcall(function()
        for _, ability_type in ipairs(_ability_types) do
            if self.ability_enabled and self:ability_enabled(ability_type) then
                local uuid  = unit_uuid(unit)
                local key   = ability_type.."_"..uuid
                local prev  = _ability_charges[key] or 0
                local cur   = current_charges(self, ability_type)
                if prev ~= cur then
                    _abilities[#_abilities+1] = {
                        player_unit_uuid = uuid,
                        ability_type     = ability_type,
                        charge_delta     = cur - prev,
                    }
                    _ability_charges[key] = cur
                end
            end
        end
    end)
    if not ok and not _ability_error_logged then
        _ability_error_logged = true
        mod:echo("DT Exporter: ability update error (shown once): "..tostring(err))
    end
end

safe_hook("PlayerUnitAbilityExtension", "update", track_ability_update)
safe_hook("PlayerHuskAbilityExtension", "update", track_ability_update)

-- 5. Psyker smite / chain-lightning special case
--    The charge system doesn't fire for these; PDI detects them via weapon
--    action name transitions in PUME_update.
safe_hook("PlayerUnitMoodExtension", "update",
    function(self, unit, dt, t)
        local ok, err = pcall(function()
            local ude = self._unit_data_extension
            if not ude then return end
            local wac = ude:read_component("weapon_action")
            if not wac then return end
            local tmpl = wac.template_name
            if tmpl ~= "psyker_smite" and tmpl ~= "psyker_chain_lightning" then return end
            local cur  = wac.current_action_name
            local uuid = unit_uuid(unit)
            if _psyker_actions[uuid] ~= cur then
                if cur == "action_use_power" or cur == "action_spread_charged" then
                    _abilities[#_abilities+1] = {
                        player_unit_uuid = uuid,
                        ability_type     = "grenade_ability",
                        charge_delta     = -1,
                    }
                end
                _psyker_actions[uuid] = cur
            end
        end)
        if not ok then
            mod:echo("DT Exporter: PUME update error: "..tostring(err))
        end
    end
)

-- 6. Reset at mission start
--    DMF callback; fires on every hub <-> mission transition.
-- (state-change handler is defined after export_stats, below)

-- ── Main export ────────────────────────────────────────────────────────────

local function export_stats(src)

    if not src then
        mod:echo("DT Exporter: ERROR - No mission data to export.")
        return
    end

    -- Shadow the live tables with the chosen snapshot
    local _spawns, _profiles, _attacks = src.spawns, src.profiles, src.attacks
    local _abilities, _interacts       = src.abilities, src.interacts
    local _pstatus, _start_time        = src.pstatus, src.start_time
    local _havoc                       = src.havoc

    if #_attacks == 0 and next(_spawns) == nil then
        mod:echo("DT Exporter: ERROR - No session data. Complete a mission first.")
        return
    end

    -- uuid_to_name: same key format as attack UUIDs, so lookups are valid
    local uuid_to_name = {}
    for uuid, v in pairs(_spawns) do
        if v.unit_name then uuid_to_name[uuid] = v.unit_name end
    end

    local player_uuids = {}
    for _, v in pairs(_pstatus) do
        if v.player_unit_uuid then player_uuids[v.player_unit_uuid] = true end
    end

    local pcount = 0
    for uuid in pairs(player_uuids) do
        pcount = pcount + 1
    end

    if pcount == 0 then
        mod:echo("DT Exporter: ERROR - No players found in session data.")
        return
    end

    local unknown_breeds = {}

    -- Solo session: kill damage formula adds raw damage to the final hit
    -- PDI_Exporter always ran against PDI's live session, which uses the
    -- "+ raw" kill formula. Our data is captured live the same way.
    local is_local_session = true

    local stats = {}
    local function ensure(name)
        if not name or name == "" then return end
        if not stats[name] then
            stats[name] = {
                melee_elite_kills=0,   ranged_elite_kills=0,
                melee_special_kills=0, ranged_special_kills=0,
                horde_trash_kills=0,   ranged_trash_kills=0,
                boss_damage=0,         elite_damage=0,
                horde_damage=0,        specialist_damage=0,
                damage_taken=0,        blitz_uses=0,
                combat_ability_uses=0, pull_up_done=0,
                remove_net_done=0,     rescue_done=0,
                revive_done=0,         needed_revives=0,
                ammo_cache=0,          large_clip=0, small_clip=0,
            }
        end
    end

    -- Damage formula mirrors dataset_templates.lua exactly:
    --   Non-kill:                  health_damage = v.damage
    --   Kill, multiplayer:         health_damage = max_hp - damage_taken
    --   Kill, solo:                health_damage = max_hp - damage_taken + v.damage
    --   Kill, no max_hp available: health_damage = 1
    for _, v in pairs(_attacks) do
        local att  = v.attacking_unit_uuid
        local def  = v.attacked_unit_uuid
        local kill = (v.attack_result == "died")
        local raw  = v.damage or 0

        local def_spawn = _spawns[def]
        local max_hp    = def_spawn and def_spawn.max_health
        local dmg_taken = v.attacked_unit_damage_taken or 0

        local health_dmg
        if kill then
            if max_hp then
                if is_local_session then
                    health_dmg = math.max(0, max_hp - dmg_taken + raw)
                else
                    health_dmg = math.max(0, max_hp - dmg_taken)
                end
            else
                health_dmg = 1
            end
        else
            health_dmg = raw
        end

        if player_uuids[att] then
            local pname = uuid_to_name[att]
            local breed = uuid_to_name[def] or ""
            if breed ~= "" and not player_uuids[def] and not is_known_breed(breed) then
                unknown_breeds[breed] = (unknown_breeds[breed] or 0) + 1
            end
            if pname then
                ensure(pname)
                local p = stats[pname]
                if     BOSS[breed]                               then p.boss_damage       = p.boss_damage       + health_dmg
                elseif MELEE_ELITE[breed] or RANGED_ELITE[breed] then p.elite_damage      = p.elite_damage      + health_dmg
                elseif HORDE_TRASH[breed] or RANGED_TRASH[breed] then p.horde_damage      = p.horde_damage      + health_dmg
                elseif MELEE_SPEC[breed]  or RANGED_SPEC[breed]  then p.specialist_damage = p.specialist_damage + health_dmg
                end
                if kill then
                    if     MELEE_ELITE[breed]  then p.melee_elite_kills    = p.melee_elite_kills    + 1
                    elseif RANGED_ELITE[breed] then p.ranged_elite_kills   = p.ranged_elite_kills   + 1
                    elseif MELEE_SPEC[breed]   then p.melee_special_kills  = p.melee_special_kills  + 1
                    elseif RANGED_SPEC[breed]  then p.ranged_special_kills = p.ranged_special_kills + 1
                    elseif HORDE_TRASH[breed]  then p.horde_trash_kills    = p.horde_trash_kills    + 1
                    elseif RANGED_TRASH[breed] then p.ranged_trash_kills   = p.ranged_trash_kills   + 1
                    end
                end
            end
        end

        if player_uuids[def] and raw > 0 then
            local pname    = uuid_to_name[def]
            local att_spawn = _spawns[att]
            if pname and att_spawn ~= nil then
                ensure(pname)
                local player_health_dmg = kill and 1 or raw
                stats[pname].damage_taken = stats[pname].damage_taken + player_health_dmg
            end
        end
    end

    for _, v in pairs(_abilities) do
        local pname  = uuid_to_name[v.player_unit_uuid]
        local ability = v.ability_type or ""
        local delta   = v.charge_delta or 0
        if pname and delta < 0 then
            ensure(pname)
            if ability == "grenade_ability" then
                stats[pname].blitz_uses = stats[pname].blitz_uses + 1
            elseif ability == "combat_ability" then
                stats[pname].combat_ability_uses = stats[pname].combat_ability_uses + 1
            end
        end
    end

    for _, v in pairs(_interacts) do
        if v.event ~= "interaction_stopped" then goto continue end
        local itype = v.interaction_type or ""
        local aname = uuid_to_name[v.interactor_unit_uuid]
        local tname = uuid_to_name[v.interactee_unit_uuid]

        if aname and player_uuids[v.interactor_unit_uuid] then
            ensure(aname)
            local p = stats[aname]
            if itype == "ammunition" then
                if     AMMO_CACHE[tname] then p.ammo_cache = p.ammo_cache + 1
                elseif LARGE_CLIP[tname] then p.large_clip = p.large_clip + 1
                elseif SMALL_CLIP[tname] then p.small_clip = p.small_clip + 1
                end
            elseif itype == "pull_up"    then p.pull_up_done    = p.pull_up_done    + 1
            elseif itype == "remove_net" then p.remove_net_done = p.remove_net_done + 1
            elseif itype == "rescue"     then p.rescue_done     = p.rescue_done     + 1
            elseif itype == "revive"     then p.revive_done     = p.revive_done     + 1
            end
        end

        if tname and player_uuids[v.interactee_unit_uuid] then
            if itype == "pull_up" or itype == "remove_net"
            or itype == "rescue"  or itype == "revive" then
                ensure(tname)
                stats[tname].needed_revives = stats[tname].needed_revives + 1
            end
        end
        ::continue::
    end

    local now   = os.date("*t")
    local start = _start_time and os.date("*t", _start_time) or now
    local date_str = string.format("%02d/%02d/%04d", start.month, start.day, start.year)
    local time_str = string.format("%02d:%02d:%02d", start.hour, start.min, start.sec)

    local equipment = {}
    for uuid, prof in pairs(_profiles) do
        local pname = uuid_to_name[uuid] or uuid

        local arch_name = "unknown"
        if type(prof.archetype) == "table" then
            arch_name = tostring(prof.archetype.name
                or prof.archetype.archetype_name
                or prof.archetype.id or "unknown")
        elseif prof.archetype then
            arch_name = tostring(prof.archetype)
        end

        local melee_weapon  = "unknown"
        local ranged_weapon = "unknown"
        if type(prof.loadout) == "table" then
            local primary   = prof.loadout["slot_primary"]
            local secondary = prof.loadout["slot_secondary"]
            if primary then
                local mi = rawget(primary, "__master_item")
                if mi and type(mi) == "table" and mi.weapon_template then
                    melee_weapon = tostring(mi.weapon_template)
                end
            end
            if secondary then
                local mi = rawget(secondary, "__master_item")
                if mi and type(mi) == "table" and mi.weapon_template then
                    ranged_weapon = tostring(mi.weapon_template)
                end
            end
        end

        local talents_selected = {}
        if type(prof.talents) == "table" then
            for k, val in pairs(prof.talents) do
                if type(val) == "number" and val > 0 then
                    talents_selected[tostring(k)] = val
                end
            end
        end

        equipment[pname] = {
            class            = arch_name,
            melee_weapon     = melee_weapon,
            ranged_weapon    = ranged_weapon,
            talents_selected = talents_selected,
        }
    end

    -- Medicae servo skull revives happen server-side and never reach the
    -- client as an interaction. With the medicae talent, every skull use (a
    -- blitz charge) is an inject on a downed ally, so credit blitz uses as
    -- revives. If the flame skull talent is ALSO selected, a blitz use could
    -- be either, so those uses are left unattributed (not counted as revives).
    -- Note: the revived player's needed_revives does not include these.
    local MEDICAE_TALENT = "cryptic_servo_skull_inject_ally"
    local FLAME_TALENT   = "cryptic_flamethrower"
    local function skull_revives(pname, p)
        local eq = equipment[pname]
        local t  = eq and eq.talents_selected
        if t and t[MEDICAE_TALENT] and not t[FLAME_TALENT] then
            return p.blitz_uses
        end
        return 0
    end

    local export  = { session_date=date_str, session_time=time_str, players={}, equipment=equipment,
                      havoc=_havoc }
    local exported = 0
    for pname, p in pairs(stats) do
        exported = exported + 1
        export.players[pname] = {
            melee_elite_kills    = p.melee_elite_kills,
            ranged_elite_kills   = p.ranged_elite_kills,
            melee_special_kills  = p.melee_special_kills,
            ranged_special_kills = p.ranged_special_kills,
            horde_trash_kills    = p.horde_trash_kills,
            ranged_trash_kills   = p.ranged_trash_kills,
            boss_damage          = math.floor(p.boss_damage),
            elite_damage         = math.floor(p.elite_damage),
            horde_damage         = math.floor(p.horde_damage),
            specialist_damage    = math.floor(p.specialist_damage),
            damage_taken         = math.floor(p.damage_taken),
            blitz_uses           = p.blitz_uses,
            combat_ability_uses  = p.combat_ability_uses,
            revives_done         = p.pull_up_done + p.remove_net_done
                                   + p.rescue_done + p.revive_done
                                   + skull_revives(pname, p),
            needed_revives       = p.needed_revives,
            ammo_used            = (p.ammo_cache * 100)
                                   + (p.large_clip  * 50)
                                   + (p.small_clip  * 15),
        }
    end

    -- Enemies hit by players that match no breed table. Their damage and kills
    -- are NOT counted anywhere until added to a table at the top of this file.
    local unknown_count = 0
    for _ in pairs(unknown_breeds) do unknown_count = unknown_count + 1 end
    if unknown_count > 0 then
        export.unknown_breeds = unknown_breeds
        log_unknown_breeds(unknown_breeds, date_str, time_str)
    end

    save_json(export)
    mod:echo("DT Exporter: Exported "..exported.." player(s)")

    if unknown_count > 0 then
        mod:echo("DT Exporter: WARNING - "..unknown_count
            .." unrecognised enemy type(s). See zz_UNKNOWN_ENEMIES file in dump")
    end
end

-- ── Auto-export on leaving a mission ──────────────────────────────────────
-- rpc_game_mode_end_conditions_met no longer fires on clients (1.13.0), so
-- we export when the next gameplay state is entered instead. The hub has no
-- combat, so hub -> mission transitions don't trigger an export.

mod.on_game_state_changed = function(status, state_name)
    if status == "enter" and state_name == "StateGameplay" then
        if #_attacks > 0 then
            _last_mission = snapshot()
            mod:echo("DT Exporter: Mission left. Exporting...")
            local ok, err = pcall(export_stats, _last_mission)
            if not ok then
                mod:echo("DT Exporter: auto-export error: "..tostring(err))
            end
        end
        reset_data()
    end
end

-- ── Manual export + commands ───────────────────────────────────────────────

mod.export_stats_manual = function()
    if in_mission() then
        mod:echo("DT Exporter: Manual export (current mission)...")
        export_stats(snapshot())
    else
        mod:echo("DT Exporter: Manual export (last completed mission)...")
        export_stats(_last_mission)
    end
end

mod.on_all_mods_loaded = function()
    mod:echo("DT Exporter loaded. Use /dt_export to export manually.")
end

mod:command("dt_export", "Export stats to JSON", function()
    mod.export_stats_manual()
end)
