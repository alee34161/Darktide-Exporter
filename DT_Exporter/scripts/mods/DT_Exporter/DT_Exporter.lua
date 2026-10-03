-- DT_Exporter: standalone Darktide stat exporter (no Power_DI dependency).

local mod = get_mod("DT_Exporter")

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
-- Writes a zz_UNKNOWN_ENEMIES file to binaries/dump for unrecognised enemies.

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
-- Unit memory address as a string key, in PDI's format.

local function unit_uuid(unit)
    if not unit then return nil end
    return "u_"..string.format("%p", unit)
end

-- ── Breed tables ───────────────────────────────────────────────────────────
-- Enemy categories. Add new enemies from zz_UNKNOWN_ENEMIES files here.

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
    renegade_wizard           = true,  -- Spillway boss
}
local function is_known_breed(b)
    return MELEE_ELITE[b] or RANGED_ELITE[b] or MELEE_SPEC[b] or RANGED_SPEC[b]
        or HORDE_TRASH[b] or RANGED_TRASH[b] or BOSS[b]
end

local AMMO_CACHE = { ammo_cache_deployable=true, ammo_cache_pocketable=true }
local LARGE_CLIP  = { large_clip=true }
local SMALL_CLIP  = { small_clip=true }

-- ── Session data ───────────────────────────────────────────────────────────
-- Live mission data. Events record names when they happen, because a dead
-- unit's memory address can be reused by a new unit.
local _spawns          = {}
local _profiles        = {}
local _attacks         = {}
local _abilities       = {}
local _interacts       = {}
local _active_ixn      = {}
local _ability_charges = {}
local _psyker_actions  = {}
local _start_time      = nil
local _havoc           = nil

local function reset_data()
    _spawns          = {}
    _profiles        = {}
    _attacks         = {}
    _abilities       = {}
    _interacts       = {}
    _active_ixn      = {}
    _ability_charges = {}
    _psyker_actions  = {}
    _start_time      = nil
    _havoc           = nil
end

-- Last mission's data, kept for /dt_export in the hub.
local _last_mission = nil

local function snapshot()
    return {
        profiles   = _profiles,
        attacks    = _attacks,
        abilities  = _abilities,
        interacts  = _interacts,
        start_time = _start_time,
        havoc      = _havoc,
    }
end

local function game_mode_name()
    local ok, name = pcall(function()
        local gm = Managers.state.game_mode
        return gm and gm:game_mode_name()
    end)
    return ok and name or nil
end

local function in_mission()
    local mode = game_mode_name()
    return mode ~= nil and mode ~= "hub"
end

-- ── Hooks ──────────────────────────────────────────────────────────────────

-- Havoc rank and mutators (circumstances); nil outside Havoc.
local function capture_havoc()
    local ok, data = pcall(function()
        local diff = Managers.state.difficulty
        return diff and diff.get_parsed_havoc_data and diff:get_parsed_havoc_data()
    end)
    if not ok or type(data) ~= "table" then return nil end

    local circumstances = {}
    for i, c in ipairs(data.circumstances or {}) do circumstances[i] = tostring(c) end

    return { rank = data.havoc_rank, circumstances = circumstances }
end

-- Copies talents as { name = tier } (1.13.0 stores a table per talent).
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

-- Registers a hook; DMF defers it until the class loads.
local function safe_hook(class_name, method_name, fn)
    local ok, err = pcall(function()
        mod:hook_safe(CLASS[class_name], method_name, fn)
    end)
    if not ok then
        mod:echo("DT Exporter: hook failed ["..class_name.."."..method_name.."]: "..tostring(err))
    end
end

-- Unit spawns: names, max health, and player profiles.
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

            local unit_name, max_health, is_player

            if template_name == "player_character" then
                local peer_id  = go_field(gs, game_object_id, "owner_peer_id")
                local local_id = go_field(gs, game_object_id, "local_player_id")
                local player   = peer_id and Managers.player:player(peer_id, local_id)
                if player and player:is_human_controlled() then
                    local profile = player:profile()
                    if profile then
                        unit_name = profile.name
                        is_player = true
                        _profiles[unit_name] = {
                            archetype = profile.archetype,
                            loadout   = profile.loadout,
                            talents   = copy_talents(profile.talents),
                        }
                    end
                end

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

            _spawns[uuid] = { unit_name = unit_name, max_health = max_health, is_player = is_player }
            _ability_charges["combat_ability_"..uuid]  = nil
            _ability_charges["grenade_ability_"..uuid] = nil
            _psyker_actions[uuid] = nil

            if not _start_time then
                _start_time = os.time()
                _havoc      = capture_havoc()
            end
        end)
        if not ok then
            mod:echo("DT Exporter: _add_network_unit error: "..tostring(err))
        end
    end
)

-- Hits: damage, kills, and damage taken.
safe_hook("AttackReportManager", "add_attack_result",
    function(self, damage_profile, attacked_unit, attacking_unit, _dir, _pos,
             hit_weakspot, damage, attack_result)
        local ok, err = pcall(function()
            local att = _spawns[unit_uuid(attacking_unit)]
            local def = _spawns[unit_uuid(attacked_unit)]
            local health_ext = attacked_unit
                and ScriptUnit.has_extension(attacked_unit, "health_system")
            _attacks[#_attacks+1] = {
                attacker_name     = att and att.unit_name,
                attacker_known    = att ~= nil,
                attacker_player   = att and att.is_player or false,
                defender_name     = def and def.unit_name,
                defender_player   = def and def.is_player or false,
                defender_max_hp   = def and def.max_health,
                defender_dmg_taken = health_ext and health_ext:damage_taken() or 0,
                damage            = damage or 0,
                killed            = attack_result == "died",
            }
        end)
        if not ok then
            mod:echo("DT Exporter: add_attack_result error: "..tostring(err))
        end
    end
)

-- Completed interactions: revives, rescues, ammo pickups.
safe_hook("InteracteeSystem", "rpc_interaction_started",
    function(self, channel_id, unit_id, is_level_unit, interactor_go_id)
        local ok, err = pcall(function()
            _active_ixn[unit_id] = Managers.state.unit_spawner:unit(interactor_go_id, false)
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

            local result_name = NetworkLookup.interaction_result
                and NetworkLookup.interaction_result[result]
            if result_name ~= "success" then return end

            local a = _spawns[unit_uuid(interactor)]
            local t = _spawns[unit_uuid(interactee)]
            _interacts[#_interacts+1] = {
                interaction_type = ext and ext:interaction_type() or nil,
                interactor_name  = a and a.is_player and a.unit_name or nil,
                interactee_name  = t and t.unit_name,
                interactee_player = t and t.is_player or false,
            }
        end)
        if not ok then
            mod:echo("DT Exporter: rpc_interaction_stopped error: "..tostring(err))
        end
    end
)

-- Ability uses, counted as charge decreases.
local _ability_types = { "combat_ability", "grenade_ability" }

-- Current charges via the 1.13.0 API, with a pre-1.13.0 fallback.
local function current_charges(self, ability_type)
    if self.remaining_ability_charges then
        return self:remaining_ability_charges(ability_type) or 0
    end
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
                if cur < prev then
                    local sp = _spawns[uuid]
                    _abilities[#_abilities+1] = {
                        player_name  = sp and sp.is_player and sp.unit_name or nil,
                        ability_type = ability_type,
                    }
                end
                _ability_charges[key] = cur
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

-- Psyker Smite / chain lightning uses, which don't consume charges.
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
                    local sp = _spawns[uuid]
                    _abilities[#_abilities+1] = {
                        player_name  = sp and sp.is_player and sp.unit_name or nil,
                        ability_type = "grenade_ability",
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

-- ── Main export ────────────────────────────────────────────────────────────
-- Builds per-player stats from a mission snapshot and saves the JSON.
-- Kill damage uses PDI's live formula: health left before the killing hit.

local function export_stats(src)
    if not src or (#src.attacks == 0 and next(src.profiles) == nil) then
        mod:echo("DT Exporter: ERROR - No mission data to export.")
        return
    end

    local stats = {}
    local function ensure(name)
        if not name or name == "" then return nil end
        if not stats[name] then
            stats[name] = {
                melee_elite_kills=0,   ranged_elite_kills=0,
                melee_special_kills=0, ranged_special_kills=0,
                horde_trash_kills=0,   ranged_trash_kills=0,
                boss_damage=0,         elite_damage=0,
                horde_damage=0,        specialist_damage=0,
                damage_taken=0,        blitz_uses=0,
                combat_ability_uses=0, revives=0,
                needed_revives=0,      ammo_cache=0,
                large_clip=0,          small_clip=0,
            }
        end
        return stats[name]
    end

    for pname in pairs(src.profiles) do ensure(pname) end
    if next(stats) == nil then
        mod:echo("DT Exporter: ERROR - No players found in session data.")
        return
    end

    local unknown_breeds = {}

    for _, v in ipairs(src.attacks) do
        local health_dmg = v.damage
        if v.killed then
            health_dmg = v.defender_max_hp
                and math.max(0, v.defender_max_hp - v.defender_dmg_taken + v.damage)
                or 1
        end

        if v.attacker_player and not v.defender_player then
            local p     = ensure(v.attacker_name)
            local breed = v.defender_name or ""
            if breed ~= "" and not is_known_breed(breed) then
                unknown_breeds[breed] = (unknown_breeds[breed] or 0) + 1
            end
            if p then
                if     BOSS[breed]                               then p.boss_damage       = p.boss_damage       + health_dmg
                elseif MELEE_ELITE[breed] or RANGED_ELITE[breed] then p.elite_damage      = p.elite_damage      + health_dmg
                elseif HORDE_TRASH[breed] or RANGED_TRASH[breed] then p.horde_damage      = p.horde_damage      + health_dmg
                elseif MELEE_SPEC[breed]  or RANGED_SPEC[breed]  then p.specialist_damage = p.specialist_damage + health_dmg
                end
                if v.killed then
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

        if v.defender_player and v.attacker_known and v.damage > 0 then
            local p = ensure(v.defender_name)
            if p then p.damage_taken = p.damage_taken + (v.killed and 1 or v.damage) end
        end
    end

    for _, v in ipairs(src.abilities) do
        local p = ensure(v.player_name)
        if p then
            if     v.ability_type == "grenade_ability" then p.blitz_uses          = p.blitz_uses          + 1
            elseif v.ability_type == "combat_ability"  then p.combat_ability_uses = p.combat_ability_uses + 1
            end
        end
    end

    local HELP_TYPES = { pull_up = true, remove_net = true, rescue = true, revive = true }
    for _, v in ipairs(src.interacts) do
        local itype = v.interaction_type or ""
        local p = ensure(v.interactor_name)
        if p then
            if itype == "ammunition" then
                local item = v.interactee_name
                if     AMMO_CACHE[item] then p.ammo_cache = p.ammo_cache + 1
                elseif LARGE_CLIP[item] then p.large_clip = p.large_clip + 1
                elseif SMALL_CLIP[item] then p.small_clip = p.small_clip + 1
                end
            elseif HELP_TYPES[itype] then
                p.revives = p.revives + 1
            end
        end
        if HELP_TYPES[itype] and v.interactee_player then
            local t = ensure(v.interactee_name)
            if t then t.needed_revives = t.needed_revives + 1 end
        end
    end

    local start = os.date("*t", src.start_time or os.time())
    local date_str = string.format("%02d/%02d/%04d", start.month, start.day, start.year)
    local time_str = string.format("%02d:%02d:%02d", start.hour, start.min, start.sec)

    local function weapon_template(item)
        local mi = item and rawget(item, "__master_item")
        return (type(mi) == "table" and mi.weapon_template) and tostring(mi.weapon_template) or "unknown"
    end

    local equipment = {}
    for pname, prof in pairs(src.profiles) do
        local arch_name = "unknown"
        if type(prof.archetype) == "table" then
            arch_name = tostring(prof.archetype.name or prof.archetype.archetype_name
                                 or prof.archetype.id or "unknown")
        elseif prof.archetype then
            arch_name = tostring(prof.archetype)
        end
        local loadout = type(prof.loadout) == "table" and prof.loadout or {}
        equipment[pname] = {
            class            = arch_name,
            melee_weapon     = weapon_template(loadout["slot_primary"]),
            ranged_weapon    = weapon_template(loadout["slot_secondary"]),
            talents_selected = prof.talents or {},
        }
    end

    local MEDICAE_TALENT = "cryptic_servo_skull_inject_ally"
    local FLAME_TALENT   = "cryptic_flamethrower"
    -- Medicae skull revives happen server-side, so a medicae Skitarii's blitz
    -- uses count as revives; with the flame skull too, they stay unattributed.
    local function skull_revives(pname, p)
        local eq = equipment[pname]
        local t  = eq and eq.talents_selected
        if t and t[MEDICAE_TALENT] and not t[FLAME_TALENT] then
            return p.blitz_uses
        end
        return 0
    end

    local export   = { session_date = date_str, session_time = time_str,
                       players = {}, equipment = equipment, havoc = src.havoc }
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
            revives_done         = p.revives + skull_revives(pname, p),
            needed_revives       = p.needed_revives,
            ammo_used            = (p.ammo_cache * 100) + (p.large_clip * 50) + (p.small_clip * 15),
        }
    end

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
-- Exports when the next gameplay state loads (the end-of-mission hook no
-- longer fires on clients). The hub has no combat, so it never exports.

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
