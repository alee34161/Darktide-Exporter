-- PDI_Exporter
-- Accesses Power_DI session data via debug.getupvalue on an exposed closure.

local mod = get_mod("PDI_Exporter")

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
        mod:echo("PDI Exporter: Saved -> binaries\\dump\\"..fname..".json")
    else
        mod:echo("PDI Exporter: ERROR - DMF:dtf not available")
    end
end

-- ── Get PDI internal data table ────────────────────────────────────────────

local function get_pdi_data()
    local PDI_mod = get_mod("Power_DI")
    if not PDI_mod then return nil end

    if PDI_mod.data then
        return PDI_mod.data
    end

    local fn = PDI_mod.get_loaded_session_id
    if fn then
        local i = 1
        while true do
            local name, val = debug.getupvalue(fn, i)
            if not name then break end
            mod:echo("PDI Exporter: upvalue["..i.."] "..name.." = "..type(val))
            if type(val) == "table" and val.data and val.datasource_manager then
                mod:echo("PDI Exporter: Found PDI table via upvalue '"..name.."'")
                return val.data
            end
            i = i + 1
        end
    end

    return nil
end

-- ── Breed tables ───────────────────────────────────────────────────────────

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
    renegade_plasma_gunner  = true,  -- Gunner variant
    renegade_radio_operator = true,  -- Gunner variant
    renegade_shocktrooper   = true,  -- Gunner variant
}
local MELEE_SPEC = {
    chaos_armored_hound    = true,  -- Hound
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
    chaos_armored_infected         = true,
    chaos_lesser_mutated_poxwalker = true,
    chaos_mutated_poxwalker        = true,
    chaos_newly_infected           = true,
    chaos_poxwalker                = true,
    cultist_melee                  = true,  -- Bruiser
    cultist_ritualist              = true,
    renegade_melee                 = true,  -- Bruiser
}
local RANGED_TRASH = {
    cultist_assault   = true,  -- Stalker
    renegade_assault  = true,  -- Stalker
    renegade_rifleman = true,  -- Shooter
}
local BOSS = {
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
local AMMO_CACHE = { ammo_cache_deployable=true, ammo_cache_pocketable=true }
local LARGE_CLIP  = { large_clip=true }
local SMALL_CLIP  = { small_clip=true }

-- ── Main export ────────────────────────────────────────────────────────────

local function export_stats()
    mod:echo("PDI Exporter: Building stats...")

    local pdi_data = get_pdi_data()
    if not pdi_data then
        mod:echo("PDI Exporter: ERROR - Could not access PDI data")
        return
    end

    local session_data = pdi_data.session_data
    if not session_data then
        mod:echo("PDI Exporter: ERROR - No session data")
        return
    end

    local ds = session_data.datasources
    if not ds then
        mod:echo("PDI Exporter: ERROR - No datasources")
        return
    end

    local attacks   = ds["AttackReportManager"]  or {}
    local spawns    = ds["UnitSpawnerManager"]   or {}
    local abilities = ds["PlayerAbilities"]      or {}
    local interacts = ds["InteracteeSystem"]     or {}
    local pstatus   = ds["PlayerUnitStatus"]     or {}
    local profiles  = ds["PlayerProfiles"]       or {}

    -- Match PDI's own is_local_session check from dataset_templates.lua
    local PDI_mod = get_mod("Power_DI")
    local is_local_session = PDI_mod and PDI_mod.get_loaded_session_id
        and PDI_mod.get_loaded_session_id() == "local"

    local spawn_count, attack_count = 0, 0
    for _ in pairs(spawns)  do spawn_count  = spawn_count  + 1 end
    for _ in pairs(attacks) do attack_count = attack_count + 1 end
    mod:echo("PDI Exporter: spawns="..spawn_count.." attacks="..attack_count)

    if spawn_count == 0 then
        mod:echo("PDI Exporter: ERROR - Datasources empty. Complete a mission first.")
        return
    end

    -- uuid_to_name: UnitSpawnerManager key (get_address) -> unit_name
    -- For players: unit_name = display name. For enemies: unit_name = breed name.
    -- Attack records use the same get_address UUID, so lookups are valid.
    local uuid_to_name = {}
    for uuid, v in pairs(spawns) do
        if v.unit_name then uuid_to_name[uuid] = v.unit_name end
    end

    local player_uuids = {}
    for _, v in pairs(pstatus) do
        if v.player_unit_uuid then player_uuids[v.player_unit_uuid] = true end
    end

    local pcount = 0
    for uuid in pairs(player_uuids) do
        pcount = pcount + 1
        mod:echo("  player: "..(uuid_to_name[uuid] or uuid))
    end
    mod:echo("PDI Exporter: "..pcount.." player(s)")

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
                ammo_cache=0,          large_clip=0,  small_clip=0,
            }

        end
    end

    -- Damage formula mirrors dataset_templates.lua exactly:
    --   Non-kill:     health_damage = v.damage
    --   Kill, non-local (multiplayer):
    --                 health_damage = defender_max_health - attacked_unit_damage_taken
    --   Kill, local (solo):
    --                 health_damage = defender_max_health - attacked_unit_damage_taken + v.damage
    --   Kill, no max_health available:
    --                 health_damage = 1
    --
    -- Player damage_taken always uses raw v.damage — the template's HP block only
    -- runs for enemies; when defender is a player it is skipped entirely.
    for _, v in pairs(attacks) do
        local att  = v.attacking_unit_uuid
        local def  = v.attacked_unit_uuid
        local kill = (v.attack_result == "died")
        local raw  = v.damage or 0

        local def_spawn     = spawns[def]
        local def_is_player = player_uuids[def]
        local max_hp        = def_spawn and def_spawn.max_health
        local dmg_taken     = v.attacked_unit_damage_taken or 0

        -- health_dmg for enemy targets (matches template formula)
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

        -- Player damage_taken: matches dataset_templates.lua + defense report filter exactly.
        -- Filter: defender_type="player" and damage>0 and attacker_class~nil and defender_player~nil
        -- health_damage for player defenders: kill=1 (no max_health), non-kill=v.damage
        -- Friendly fire IS included (minion_categories["player"].class = "mloc_player", not nil)
        if def_is_player and raw > 0 then
            local pname = uuid_to_name[def]
            -- attacker_class~nil: attacker must have a minion_categories entry.
            -- We approximate this by checking if the attacker has a known unit_name in spawns.
            -- Players always pass (class="mloc_player"). Unknown attackers (no spawn entry) fail.
            local att_spawn = spawns[att]
            local att_has_class = att_spawn ~= nil  -- any spawned unit has a category entry
            if pname and att_has_class then
                ensure(pname)
                -- health_damage for player defender: killed=1 (no max_health), else v.damage
                local player_health_dmg = kill and 1 or raw
                stats[pname].damage_taken = stats[pname].damage_taken + player_health_dmg
            end
        end
    end

    -- Debug: print per-player damage totals
    for pname, p in pairs(stats) do
        mod:echo(pname.." elite_dmg="..math.floor(p.elite_damage)
            .." horde_dmg="..math.floor(p.horde_damage)
            .." boss_dmg="..math.floor(p.boss_damage)
            .." spec_dmg="..math.floor(p.specialist_damage))
    end

    for _, v in pairs(abilities) do
        local pname   = uuid_to_name[v.player_unit_uuid]
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

    for _, v in pairs(interacts) do
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

    local info  = session_data.info or {}
    local now   = os.date("*t")
    local start = info.start_time
    local date_str, time_str
    if start then
        local t = os.date("*t", start)
        date_str = string.format("%02d/%02d/%04d", t.month, t.day, t.year)
        time_str = string.format("%02d:%02d:%02d", t.hour, t.min, t.sec)
    else
        date_str = string.format("%02d/%02d/%04d", now.month, now.day, now.year)
        time_str = string.format("%02d:%02d:%02d", now.hour, now.min, now.sec)
    end

    -- Extract equipment from PlayerProfiles
    local equipment = {}
    for uuid, prof in pairs(profiles) do
        local pname = uuid_to_name[uuid] or uuid

        -- Class from archetype
        local arch_name = "unknown"
        if type(prof.archetype) == "table" then
            arch_name = tostring(prof.archetype.name or prof.archetype.archetype_name or prof.archetype.id or "unknown")
        elseif prof.archetype then
            arch_name = tostring(prof.archetype)
        end

        -- Weapon templates from loadout slots
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

        -- Full talents_selected list for lookup resolution in app.py
        local talents_selected = {}
        if type(prof.talents) == "table" then
            for k, v in pairs(prof.talents) do
                if type(v) == "number" and v > 0 then
                    talents_selected[tostring(k)] = v
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

    local export = { session_date=date_str, session_time=time_str, players={}, equipment=equipment }
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
                                   + p.rescue_done + p.revive_done,
            needed_revives       = p.needed_revives,
            ammo_used            = (p.ammo_cache * 100)
                                   + (p.large_clip * 50)
                                   + (p.small_clip * 15),
        }
    end

    mod:echo("PDI Exporter: Exported "..exported.." player(s)")
    save_json(export)
end

-- ── Timer + hooks ──────────────────────────────────────────────────────────

local _countdown = nil
local DELAY      = 5.0

mod.on_update = function(dt)
    if _countdown then
        _countdown = _countdown - dt
        if _countdown <= 0 then
            _countdown = nil
            export_stats()
        end
    end
end

mod:hook_safe(CLASS.GameModeManager, "rpc_game_mode_end_conditions_met",
    function(self, channel_id, outcome_id)
        mod:echo(string.format("PDI Exporter: Mission end. Exporting in %ds...", DELAY))
        _countdown = DELAY
    end
)

mod.export_stats_manual = function()
    mod:echo("PDI Exporter: Manual export...")
    export_stats()
end

mod.on_all_mods_loaded = function()
    mod:echo("PDI Exporter loaded. Use /pdi_export to export.")
end

mod:command("pdi_export", "Export PDI stats to JSON", function()
    mod.export_stats_manual()
end)
