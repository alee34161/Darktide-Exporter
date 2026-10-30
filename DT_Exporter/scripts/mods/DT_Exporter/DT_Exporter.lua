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
    chaos_mutator_ritualist = true,  -- Ritualist (Heinous Rituals)
    chaos_ogryn_bulwark     = true,  -- Crusher
    chaos_ogryn_executor    = true,  -- Mauler variant
    cultist_berzerker       = true,  -- Rager
    renegade_berzerker      = true,  -- Rager variant
    renegade_executor       = true,  -- Mauler
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
    chaos_armored_hound     = true,  -- Armored Hound
    chaos_hound             = true,  -- Hound
    chaos_poxwalker_bomber  = true,  -- Burster
    cultist_flamer          = true,  -- Flamer
    cultist_grenadier       = true,  -- Bomber
    cultist_mutant          = true,  -- Mutant
    cultist_mutant_mutator  = true,  -- Mutant variant
    renegade_flamer         = true,  -- Flamer
    renegade_flamer_mutator = true,  -- Flamer variant
    renegade_netgunner      = true,  -- Trapper
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
    chaos_daemonhost_torment  = true,  -- Event Daemonhost
    chaos_mutator_daemonhost  = true,  -- Mutator Daemonhost
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
local _outcome         = nil
local _deaths          = {}
local _orphans         = {}
local _recovered       = 0
local _unmatched       = 0
local _tracked         = {}

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
    _outcome         = nil
    _deaths          = {}
    _orphans         = {}
    _recovered       = 0
    _unmatched       = 0
    _tracked         = {}
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
        recovered  = _recovered,
        unmatched  = _unmatched,
        havoc      = _havoc,
        outcome    = _outcome,
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

-- ── Enemy health ───────────────────────────────────────────────────────────
-- The server's per-hit damage limit for an enemy type (e.g. 0.025 for the
-- Spillway boss), read from the game's breed data.
local _breeds = nil
local function breed_hit_clamp(breed_name)
    if not breed_name then return nil end
    if _breeds == nil then
        local ok, b = pcall(require, "scripts/settings/breed/breeds")
        _breeds = ok and type(b) == "table" and b or false
    end
    local breed = _breeds and _breeds[breed_name]
    return breed and breed.clamp_health_percent_damage or nil
end

-- The enemy's damage taken as sent by the server (includes healing), or nil.
local function server_damage(unit, go_id)
    local ok, dmg = pcall(function()
        local gs = Managers.state.game_session:game_session()
        if not gs or not go_id or Managers.state.unit_spawner:unit(go_id) ~= unit then return nil end
        if not GameSession.game_object_exists(gs, go_id) then return nil end
        if not GameSession.has_game_object_field(gs, go_id, "damage") then return nil end
        return GameSession.game_object_field(gs, go_id, "damage")
    end)
    return ok and dmg or nil
end

-- Blighted Stimms (green): the server heals a stimmed enemy by each hit's
-- damage until a pool of max health x a difficulty multiplier runs out. These
-- heals land in the same network update as the hit, so they are replicated here.
local GREEN_STIMMS = { "mutator_stimmed_minion_green", "ogryn_mutator_stimmed_minion_green" }
local _stimm_mult = nil
local function green_stimm_pool(unit, max_hp)
    local ok, pool = pcall(function()
        local buff_ext = ScriptUnit.has_extension(unit, "buff_system")
        if not buff_ext then return nil end
        local stimmed = false
        for _, name in ipairs(GREEN_STIMMS) do
            if buff_ext:has_buff_using_buff_template(name) then stimmed = true end
        end
        if not stimmed then return nil end
        if _stimm_mult == nil then
            local settings = require("scripts/settings/havoc/havoc_mutator_local_settings")
            local mults = settings.mutator_stimmed_minions.buff_settings.green_stimm_settings.heal_multipliers
            _stimm_mult = Managers.state.difficulty:get_table_entry_by_challenge(mults) or false
        end
        return _stimm_mult and max_hp * _stimm_mult or nil
    end)
    return ok and pool or nil
end

local function gameplay_time()
    local ok, t = pcall(function() return Managers.time:time("gameplay") end)
    return ok and t or os.clock()
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

            _spawns[uuid] = {
                unit_name   = unit_name,
                max_health  = max_health,
                is_player   = is_player,
                go_id       = game_object_id,
                hit_clamp   = not is_player and breed_hit_clamp(unit_name) or nil,
                damage_seen = 0,
                healed      = 0,
            }
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

-- Hits: damage, kills, and damage taken. Each enemy keeps a running total
-- of reported damage from every attacker, applying the server's per-hit limit
-- and subtracting healing. A killing hit is credited only the health the
-- enemy had left, so overkill is excluded.
local RECOVER_WINDOW = 30
local ORPHAN_WINDOW  = 2

-- Reads the enemy's server damage; a drop means it was healed (unless its
-- heals are already replicated from Blighted Stimms).
local function observe_server_damage(def, unit)
    local srv = server_damage(unit, def.go_id)
    if not srv then return false end
    if def.last_srv and srv < def.last_srv and not def.stimm_pool then
        local heal = def.last_srv - srv
        def.healed      = def.healed + heal
        def.damage_seen = math.max(0, def.damage_seen - heal)
    end
    def.last_srv = srv
    return true
end

-- The server's per-hit damage limit for this enemy, if it has one.
local function clamp_hit(def, raw)
    if def.hit_clamp and def.max_health then
        return math.min(raw, def.max_health * def.hit_clamp)
    end
    return raw
end

-- Adds a non-killing hit to the enemy's running total, then applies the
-- Blighted Stimms heal the server gives for it.
local function apply_hit(def, amount)
    def.damage_seen = def.damage_seen + amount
    if def.stimm_pool and def.stimm_pool > 0 then
        local heal = math.min(def.stimm_pool, amount)
        def.stimm_pool  = def.stimm_pool - heal
        def.healed      = def.healed + heal
        def.damage_seen = math.max(0, def.damage_seen - heal)
    end
end

-- Health the dead enemy lost that no hit report has accounted for yet.
local function unaccounted(def)
    return (def.max_health or 0) + def.healed - def.damage_seen
end

local function record_kill_on(def, raw)
    local max_hp = def.max_health
    local seen   = def.damage_seen or 0
    local credit = max_hp and math.min(raw, math.max(0, max_hp - seen)) or 1
    def.damage_seen = seen + credit
    def.killed      = true
    return credit
end

local function add_recovered(att, def, raw, credit, killed)
    _attacks[#_attacks+1] = {
        attacker_name   = att.unit_name,
        attacker_known  = true,
        attacker_player = true,
        defender_name   = def.unit_name,
        defender_player = false,
        damage          = raw,
        health_dmg      = credit,
        killed          = killed,
        enemy           = def,
    }
end

-- Pairs a kill report that arrived without a target with an enemy that died
-- with no kill report of its own. Kills by players are credited; kills by
-- other enemies only use up that death.
local function pair_orphan(att, raw, def)
    if not (att and att.is_player) then
        def.killed = true
        return
    end
    _recovered = _recovered + 1
    add_recovered(att, def, raw, record_kill_on(def, raw), true)
end

-- Oldest entry still in the window, preferring one that matches; removed.
local function take_best(list, now, window, prefer)
    local first_i, pref_i
    for i = 1, #list do
        local e = list[i]
        if now - e.time <= window and not (e.def and e.def.killed) then
            first_i = first_i or i
            if prefer and prefer(e) then pref_i = i break end
        end
    end
    local i = pref_i or first_i
    return i and table.remove(list, i) or nil
end

-- Non-killing hits that arrive without a target belong to an enemy that died
-- before the report was sent. The hit is added to a pending death, preferring
-- one the attacker hit last and one with enough unaccounted health, and is
-- never credited more than that health.
local function attach_hit(att, raw, now)
    local name = att and att.unit_name
    local pick, pick_fit, pick_big
    for _, e in ipairs(_deaths) do
        local def = e.def
        if now - e.time <= RECOVER_WINDOW and not def.killed then
            local room = unaccounted(def)
            local amt  = clamp_hit(def, raw)
            if room > 0 then
                if name and def.last_hitter == name and room >= amt then pick = pick or e end
                if room >= amt then pick_fit = pick_fit or e end
                if not pick_big or room > unaccounted(pick_big.def) then pick_big = e end
            end
        end
    end
    local e = pick or pick_fit or pick_big
    if not e then return nil end
    local def    = e.def
    local credit = math.min(clamp_hit(def, raw), unaccounted(def))
    apply_hit(def, credit)
    if att and att.is_player then add_recovered(att, def, raw, credit, false) end
    return def, credit
end

safe_hook("AttackReportManager", "add_attack_result",
    function(self, damage_profile, attacked_unit, attacking_unit, _dir, _pos,
             hit_weakspot, damage, attack_result)
        local ok, err = pcall(function()
            local att    = _spawns[unit_uuid(attacking_unit)]
            local def    = _spawns[unit_uuid(attacked_unit)]
            local raw    = damage or 0
            local killed = attack_result == "died"

            if not attacked_unit then
                local now = gameplay_time()
                if killed then
                    local name  = att and att.unit_name
                    local death = take_best(_deaths, now, RECOVER_WINDOW, function(e) return name ~= nil and e.def.last_hitter == name end)
                    if death then
                        pair_orphan(att, raw, death.def)
                    else
                        _orphans[#_orphans+1] = { att = att, raw = raw, time = now }
                    end
                elseif raw > 0 then
                    attach_hit(att, raw, now)
                end
                return
            end

            local health_dmg = raw
            if def and not def.is_player then
                if def.stimm_pool == nil and def.max_health then
                    def.stimm_pool = green_stimm_pool(attacked_unit, def.max_health) or nil
                end
                observe_server_damage(def, attacked_unit)
                if not killed then _tracked[def] = attacked_unit end
                raw = clamp_hit(def, raw)
                if killed then
                    health_dmg = record_kill_on(def, raw)
                else
                    health_dmg = raw
                    apply_hit(def, raw)
                end
                if att and att.is_player then def.last_hitter = att.unit_name end
            elseif killed and not def then
                health_dmg = 1
            end

            _attacks[#_attacks+1] = {
                attacker_name   = att and att.unit_name,
                attacker_known  = att ~= nil,
                attacker_player = att and att.is_player or false,
                defender_name   = def and def.unit_name,
                defender_player = def and def.is_player or false,
                damage          = damage or 0,
                health_dmg      = health_dmg,
                killed          = killed,
                enemy           = def and not def.is_player and def or nil,
            }
        end)
        if not ok then
            mod:echo("DT Exporter: add_attack_result error: "..tostring(err))
        end
    end
)

-- Enemy deaths on clients. A death without a kill report is kept for up to
-- 30 seconds (the server holds hit reports back while a player's connection
-- falls behind) so late reports without a target can be paired with it. A
-- targetless kill report that arrives first waits 2 seconds for its death.
safe_hook("MinionDeathManager", "rpc_minion_set_dead",
    function(self, channel_id, unit_id)
        local ok, err = pcall(function()
            local unit = Managers.state.unit_spawner:unit(unit_id)
            local def  = unit and _spawns[unit_uuid(unit)]
            if not def or def.is_player or def.killed then return end
            local now    = gameplay_time()
            local orphan = take_best(_orphans, now, ORPHAN_WINDOW, function(e) return e.att ~= nil and e.att.unit_name == def.last_hitter end)
            if orphan then
                pair_orphan(orphan.att, orphan.raw, def)
            else
                _deaths[#_deaths+1] = { def = def, time = now }
            end
        end)
        if not ok then
            mod:echo("DT Exporter: rpc_minion_set_dead error: "..tostring(err))
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

-- Whether a player can be using abilities: alive, and not dead or hogtied
-- (death unequips abilities, which empties their charges).
local function can_use_abilities(unit)
    if not HEALTH_ALIVE[unit] then return false end
    local ude   = ScriptUnit.has_extension(unit, "unit_data_system")
    local cs    = ude and ude:read_component("character_state")
    local state = cs and cs.state_name
    return state ~= "dead" and state ~= "hogtied"
end

local function track_ability_update(self, unit, dt, t)
    local ok, err = pcall(function()
        local uuid   = unit_uuid(unit)
        local usable = can_use_abilities(unit)
        for _, ability_type in ipairs(_ability_types) do
            local key = ability_type.."_"..uuid
            if usable and self.ability_enabled and self:ability_enabled(ability_type) then
                local prev = _ability_charges[key] or 0
                local cur  = current_charges(self, ability_type)
                if cur < prev then
                    local sp = _spawns[uuid]
                    _abilities[#_abilities+1] = {
                        player_name  = sp and sp.is_player and sp.unit_name or nil,
                        ability_type = ability_type,
                    }
                end
                _ability_charges[key] = cur
            else
                _ability_charges[key] = nil
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
-- Per-boss factors that scale credited damage down to what the server actually
-- removed (phase protection, unkillable phases), keeping each player's share.
local function boss_scales(attacks)
    local credit, scale = {}, {}
    for _, v in ipairs(attacks) do
        local e = v.enemy
        if e and BOSS[e.unit_name] then credit[e] = (credit[e] or 0) + v.health_dmg end
    end
    for e, credited in pairs(credit) do
        local applied = e.killed and e.max_health or e.last_srv
        if applied and credited > 0 then
            scale[e] = math.min(1, (applied + (e.healed or 0)) / credited)
        end
    end
    return scale
end

-- Builds per-player stats from a mission snapshot and saves the JSON.

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

    local boss_scale = boss_scales(src.attacks)

    local unknown_breeds = {}

    for _, v in ipairs(src.attacks) do
        local health_dmg = v.health_dmg * (v.enemy and boss_scale[v.enemy] or 1)

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
                       outcome = src.outcome or "unfinished",
                       recovered_kills = src.recovered or 0,
                       unmatched_kills = src.unmatched or 0,
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
    if (src.recovered or 0) > 0 or (src.unmatched or 0) > 0 then
        mod:echo(string.format("DT Exporter: %d targetless kill(s) recovered, %d unmatched",
            src.recovered or 0, src.unmatched or 0))
    end

    if unknown_count > 0 then
        mod:echo("DT Exporter: WARNING - "..unknown_count
            .." unrecognised enemy type(s). See zz_UNKNOWN_ENEMIES file in dump")
    end
end

-- ── Mission outcome ────────────────────────────────────────────────────────
-- The client's game mode manager stores the result when the mission ends; it
-- is replaced on leaving, so the result is captured while still in the mission.

local OUTCOME_LABELS = { won = "win", lost = "loss" }

-- Drops deaths and targetless kill reports that found no match in time.
local function prune_recovery()
    local now = gameplay_time()
    for i = #_deaths, 1, -1 do
        if now - _deaths[i].time > RECOVER_WINDOW then table.remove(_deaths, i) end
    end
    for i = #_orphans, 1, -1 do
        if now - _orphans[i].time > ORPHAN_WINDOW then
            if _orphans[i].att and _orphans[i].att.is_player then _unmatched = _unmatched + 1 end
            table.remove(_orphans, i)
        end
    end
end

-- Reads the server damage of every damaged, living enemy once per frame, so
-- healing between hits is seen and bosses end on their latest health.
local function refresh_tracked()
    for def, unit in pairs(_tracked) do
        if def.killed or not observe_server_damage(def, unit) then _tracked[def] = nil end
    end
end

mod.update = function()
    if #_deaths > 0 or #_orphans > 0 then prune_recovery() end
    if next(_tracked) then pcall(refresh_tracked) end
    if _outcome or #_attacks == 0 then return end
    local ok, result = pcall(function()
        return Managers.state.game_mode:end_conditions_met_outcome()
    end)
    if ok and result then
        _outcome = OUTCOME_LABELS[result] or tostring(result)
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
