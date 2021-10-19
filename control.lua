local NDCache = require "NDCache"
local Scanner = require "Scanner"
local ActionTypes = require "ActionTypes"
local Constants = require "Constants"
local HelpFunctions = require "HelpFunctions"

local cache = NDCache.new(Scanner.generator)
local player_state
local cycle_length_in_ticks = settings.global["autobuild-cycle-length-in-ticks"].value



local function get_player_state(player_index)
  local state = player_state[player_index]
  if not state then
    state = {}
    state.enable_tiles = true --default enabled
    state.actions_per_cycle = settings.get_player_settings(player_index)["autobuild-actions-per-cycle"].value
    state.idle_cycles_before_recheck = settings.get_player_settings(player_index)["autobuild-idle-cycles-before-recheck"].value
    state.visual_area_opacity = settings.get_player_settings(player_index)["autobuild-visual-area-opacity"].value
    state.last_successful_build_tick = 0

    player_state[player_index] = state
  end
  return state
end

local function change_visual_area(player, state, opacity)
  
  if state.visual_area_id then
    rendering.destroy(state.visual_area_id)
    state.visual_area_id = nil
  end

  if not opacity or opacity <= 0 then return end

  local radius = state.build_distance + 0.5

  state.visual_area_id = rendering.draw_rectangle({
    surface = player.surface,
    filled = true,
    draw_on_ground = true,
    color = { r=(opacity/200), g=(opacity/200), b=0, a=(opacity/200) },
    left_top = player.character,
    left_top_offset = { -radius, -radius },
    right_bottom = player.character,
    right_bottom_offset = { radius, radius }
  })
end

local function on_load()
  player_state = global.player_state
end
script.on_load(on_load)

local function on_init()
  global.player_state = {}
  on_load()
end
script.on_init(on_init)

local function on_configuration_changed()
  global.player_state = {}
  on_load()
end
script.on_configuration_changed(on_configuration_changed)

local function toggle_enabled_construction(player)
  local state = get_player_state(player.index)
  local enable = not state.enable_construction

  state.enable_construction = enable
  
  state.build_candidates = nil
  state.candidate_iter = nil

  if enable then
    state.surface_name = player.surface.name
    state.position = player.position
    state.build_distance = player.build_distance
    
    change_visual_area(player, state, state.visual_area_opacity)
  else
    state.surface_name = nil
    state.position = nil
    state.build_distance = nil

    change_visual_area(nil, state, nil)
  end

  state.is_building_phase = enable

  player.set_shortcut_toggled("autobuild-shortcut-toggle-construction", enable)

  if enable then
    player.print{"autobuild-message.construction-enabled"}
  else
    player.print{"autobuild-message.construction-disabled"}
  end
end

local function toggle_enabled_tiles(player)
  local state = get_player_state(player.index)
  local enable = not state.enable_tiles
  
  state.enable_tiles = enable

  if enable then
    player.print{"autobuild-message.tiles-enabled"}
  else
    player.print{"autobuild-message.tiles-disabled"}
  end
end

local floor = math.floor
local function entity_chunk_key(entity)
  local position = entity.position
  return {
    entity.surface.name,
    floor(position.x / Constants.AREA_SIZE),
    floor(position.y / Constants.AREA_SIZE),
  }
end

-- force_recheck triggers building instantly, after a blueprint is placed
local force_recheck = false
local function entity_changed(event)
  cache:invalidate(entity_chunk_key(event.entity or event.created_entity))
  force_recheck = true
end

local function entity_built(event)
  local entity = event.entity or event.destination

  local action_type = ActionTypes.get_action_type(entity)
  if action_type == ActionTypes.ENTITY_GHOST or action_type == ActionTypes.TILE_GHOST then
    cache:invalidate(entity_chunk_key(entity))
    force_recheck = true
  end
end

local event_handlers = {
  on_entity_cloned = entity_built,
  on_entity_died = entity_changed,

  on_lua_shortcut = function(event)
    if event.prototype_name ~= "autobuild-shortcut-toggle-construction" then return end
    local player = game.players[event.player_index]
    toggle_enabled_construction(player)
  end,

  on_marked_for_deconstruction = entity_changed,
  on_marked_for_upgrade = entity_changed,

  on_player_changed_position = function(event)
    local state = get_player_state(event.player_index)
    state.motionless_cycles = 0
  end,

  script_raised_built = entity_built,

  ["autobuild-custominput-toggle-construction"] = function(event)
    local player = game.players[event.player_index]
    toggle_enabled_construction(player)
  end,

  ["autobuild-custominput-toggle-tiles"] = function(event)
    local player = game.players[event.player_index]
    toggle_enabled_tiles(player)
  end,
}

for event_name, handler in pairs (event_handlers) do
  script.on_event(defines.events[event_name] or event_name, handler)
end

script.on_event(defines.events.on_built_entity, entity_changed, {{ filter = "ghost" }})

local to_place_cache = {}
local function to_place(entity_name)
  local stacks = to_place_cache[entity_name]
  if not stacks then
    local prototype = game.entity_prototypes[entity_name] or game.tile_prototypes[entity_name]
    stacks = prototype and prototype.items_to_place_this
    for _, stack in pairs(stacks) do
      stack.prototype = game.item_prototypes[stack.name]
    end
    to_place_cache[entity_name] = stacks or {}
  end
  return stacks
end

local function try_insert_requested(entity, request_proxy, player)
  local requested = request_proxy.item_requests
  for name, required in pairs(requested) do
    local to_insert = math.min(player.get_item_count(name), required)
    if to_insert > 0 then
      local inserted = entity.insert{name = name, count = to_insert}
      if inserted > 0 then
        player.remove_item{name = name, count = inserted}
        if inserted == required then
          requested[name] = nil
        else
          requested[name] = required - inserted
        end
      end
    end
  end
  request_proxy.item_requests = requested
end

local function insert_or_spill(player, entity, name, count)
  local inserted = player.insert{name=name, count=count}
  if inserted < count then
    entity.surface.spill_item_stack(entity.position, {name = name, count = count - inserted})
  end
end

local function try_revive_with_stack(ghost, player, stack_to_place)
  if player.get_item_count(stack_to_place.name) < stack_to_place.count then
    return false
  end

  local items, entity, request_proxy = ghost.revive{
    return_item_request_proxy = true,
    raise_revive = true,
  }
  if not items then return false end

  for name, count in pairs(items) do
    insert_or_spill(player, entity, name, count)
  end
  player.remove_item(stack_to_place)

  if request_proxy then
    try_insert_requested(entity, request_proxy, player)
  end

  return items ~= nil
end

local function try_upgrade_with_stack(entity, target_name, player, stack_to_place)
  if player.get_item_count(stack_to_place.name) < stack_to_place.count then
    return false
  end

  local entity = entity.surface.create_entity{
    name = target_name,
    position = entity.position,
    direction = entity.direction,
    force = entity.force,
    fast_replace = true,
    player = player,
    type = entity.type:find("loader") and entity.loader_type or
      entity.type == "underground-belt" and entity.belt_to_ground_type,
    raise_built = true,
  }
  if entity then
    player.remove_item(stack_to_place)
    return true
  end
  return false
end

local function try_revive_entity(entity, player, state)
  local stacks_to_place = to_place(entity.ghost_name)
  for _, stack_to_place in pairs(stacks_to_place) do
    local success = try_revive_with_stack(entity, player, stack_to_place)
    if success then return success end
  end
end

local function try_revive_tile(entity, player, state)
  if state.enable_tiles then
    return try_revive_entity(entity, player, state)
  end
end

local function try_upgrade_single_entity(entity, player)
  local target_proto = entity.get_upgrade_target()
  if not target_proto then return false end
  local target_name = target_proto.name
  local stacks_to_place = to_place(target_name)
  for _, stack_to_place in pairs(stacks_to_place) do
    local success = try_upgrade_with_stack(entity, target_name, player, stack_to_place)
    if success then return success end
  end
end

local function try_upgrade_paired_entity(entity, other_entity, player)
  local success = try_upgrade_single_entity(entity, player)
  local other_success = try_upgrade_single_entity(other_entity, player)
  return success or other_success
end

local function try_upgrade(entity, player, state)
  if entity.type == "underground-belt" and entity.neighbours then
    return try_upgrade_paired_entity(entity, entity.neighbours, player)
  elseif entity.type == "pipe-to-ground" and entity.neighbours[1] and entity.neighbours[1][1] then
    return try_upgrade_paired_entity(entity, entity.neighbours[1][1], player)
  else
    return try_upgrade_single_entity(entity, player)
  end
end

local function try_deconstruct_tile(entity, player, state)
  local position = entity.position
  return player.mine_tile(entity.surface.get_tile(position.x, position.y))
end

local function try_deconstruct_entity(entity, player, state)
  return player.mine_entity(entity)
end

local build_actions = 
{
  [ActionTypes.DECONSTRUCT] = try_deconstruct_entity,
  [ActionTypes.DECONSTRUCT_TILE] = try_deconstruct_tile,
  [ActionTypes.ENTITY_GHOST] = try_revive_entity,
  [ActionTypes.TILE_GHOST] = try_revive_tile,
  [ActionTypes.UPGRADE] = try_upgrade,
}

local function try_candidate(entry, player, state)
  if not entry or not entry.action_type or entry.action_type <= ActionTypes.NONE then
    return false
  end

  local entity = entry.entity
  if not entity or not entity.valid then
    return false
  end

  local build_action = build_actions[entry.action_type]
  if build_action then 
    return build_action(entity, player, state)
  end

  return false
end

local function get_candidates(state)
  
  local candidates = state.build_candidates
  if candidates then
    return candidates
  end

  if not state.surface_name then return nil end
  if not state.position then return nil end
  if not state.build_distance then return nil end

  local build_distance = math.min(state.build_distance + 0.5, Constants.MAX_DISTANCE)
  candidates = Scanner.find_candidates(
    cache,
    state.surface_name,
    state.position,
    build_distance,
    Constants.MAX_CANDIDATES)
  state.build_candidates = candidates
  state.candidate_iter = nil
  
  return candidates
end

local function do_autobuild(state, player)
  local candidates = get_candidates(state)
  if not candidates then return end

  local candidate = nil
  local remainingActions = state.actions_per_cycle
  repeat
    state.candidate_iter, candidate = next(candidates, state.candidate_iter)
    if candidate then
      if try_candidate(candidate, player, state) then
        remainingActions = remainingActions - 1
        state.last_successful_build_tick = game.tick
        if HelpFunctions.check_severity(5) then
          HelpFunctions.log_it(string.format("cycle: %d: %s on position: %d/%d",
              state.current_cycle, ActionTypes.get_action_verb(candidate.action_type),
              candidate.position.x, candidate.position.y))
        end
      end
    end
  until (not candidate) or (remainingActions == 0)

  if not candidate then
    -- no building candidates on current position -> stop building phase
    state.is_building_phase = false
  end
end

-- needs_rechecks
-- Determines, whether the area around the player should be rechecked (mainly from cache, but might also get rescanned, if something changed in the blueprint)
-- Also, the building candidates are getting reordered according to action_type and player position.
-- returns true -> yes: recheck
-- returns false -> no: don't recheck, build further on the old location 
local function needs_recheck(player, state)
  -- increment current_cycle
  local current_cycle = (state.current_cycle or 0) 
  state.current_cycle = current_cycle + 1
  
  -- increment motionless cycle, which gets reset, when player moves.
  local motionless_cycles = (state.motionless_cycles or 0) 
  state.motionless_cycles = motionless_cycles + 1
  
  if force_recheck then
    if HelpFunctions.check_severity(3) then HelpFunctions.log_it(string.format("cycle: %d: force recheck", current_cycle)) end
    return true -- force recheck
  end

  -- always recheck once every 12 (idle_cycles_before_recheck) cycles, regardless of other conditions
  local is_recheck_cycle = (current_cycle % state.idle_cycles_before_recheck) == 0
  if is_recheck_cycle then
    if HelpFunctions.check_severity(3) then HelpFunctions.log_it(string.format("cycle: %d: recheck regular cycle", current_cycle)) end
    return true -- recheck cycle
  end
    
  -- if player is standing still, no recheck
  if motionless_cycles >= 1 then 
    if HelpFunctions.check_severity(4) then HelpFunctions.log_it(string.format("cycle: %d: no recheck: not moved recently", current_cycle)) end
    return false --no recheck
  end 

  -- this is a pause state, which can only be left by the recheck cycle every 12 (idle_cycles_before_recheck) cycles (and if new building candidates are detected)
  -- no recheck, if 5 sec. has been past, without any successful building action.
  if not is_building_phase then

    local ticks_since_last_successful_build = game.tick - state.last_successful_build_tick

    if ticks_since_last_successful_build >= 300 then -- 5 sec.
      if HelpFunctions.check_severity(3) then HelpFunctions.log_it(string.format("cycle: %d: no recheck: not built recently", current_cycle)) end
      return false--no recheck
    end
  end

  if HelpFunctions.check_severity(3) then HelpFunctions.log_it(string.format("cycle: %d: recheck normal", current_cycle)) end
  return true
end

local god_controller = defines.controllers.god
local character_controller = defines.controllers.character
local function handle_player_update(player)
  local state = get_player_state(player.index)
  if not state.enable_construction then return end

  local controller = player.controller_type
  if controller ~= god_controller and controller ~= character_controller then
    -- don't allow spectators or characters awaiting respawn to act
    return
  end

  if player.in_combat then return end

  if needs_recheck(player, state) then
    -- player has moved
    -- or once every 12 cycles (state.idle_cycles_before_recheck)
    state.build_candidates = nil
    state.candidate_iter = nil

    state.surface_name = player.surface.name
    state.position = player.position
    state.build_distance = player.build_distance

    state.is_building_phase = true
  end

  -- build on last position, if recheck was not necessary
  if state.is_building_phase then
    do_autobuild(state, player)
  end 
end

function update_cycle(event)
  for _, player in pairs(game.connected_players) do
    handle_player_update(player)
  end
  force_recheck = false
end

script.on_nth_tick(cycle_length_in_ticks, update_cycle)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  local state = get_player_state(event.player_index)

  if event.setting == "autobuild-cycle-length-in-ticks" then
    --unregister with old value
    script.on_nth_tick(cycle_length_in_ticks, nil)
    cycle_length_in_ticks = settings.global[event.setting].value
    --register with new value
    script.on_nth_tick(cycle_length_in_ticks, update_cycle)
  
  elseif event.setting == "autobuild-log-level" then
    HelpFunctions.log_level = settings.global[event.setting].value

  elseif event.setting == "autobuild-actions-per-cycle" then
    state.actions_per_cycle = settings.get_player_settings(event.player_index)[event.setting].value
  elseif event.setting == "autobuild-idle-cycles-before-recheck" then
    state.idle_cycles_before_recheck = settings.get_player_settings(event.player_index)[event.setting].value
  elseif event.setting == "autobuild-visual-area-opacity" then
    state.visual_area_opacity = settings.get_player_settings(event.player_index)[event.setting].value
    local player = game.players[event.player_index]
    change_visual_area(player, state, state.visual_area_opacity)
  end

end)