local NDCache = require "NDCache"
local Scanner = require "Scanner"
local ActionTypes = require "ActionTypes"
local Constants = require "Constants"

local cache = NDCache.new(Scanner.generator)
local player_state

local function get_player_state(player_index)
  local state = player_state[player_index]
  if not state then
    state = {}
    state.enable_tiles = true --default enabled
    state.action_rate = settings.get_player_settings(event.player_index)[event.setting].value
    player_state[player_index] = state
  end
  return state
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
end
script.on_configuration_changed(on_configuration_changed)

local function toggle_enabled_construction(player)
  local state = get_player_state(player.index)
  local enable = not state.enable_construction

  state.enable_construction = enable
  state.enable_deconstruction = enable

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

local function entity_changed(event)
  cache:invalidate(entity_chunk_key(event.entity or event.created_entity))
end

local function entity_built(event)
  local entity = event.entity or event.destination

  local action_type = ActionTypes.get_action_type(entity)
  if action_type == ActionTypes.ENTITY_GHOST or action_type == ActionTypes.TILE_GHOST then
    cache:invalidate(entity_chunk_key(entity))
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
    state.motionless_updates = 0
    state.build_candidates = nil
    state.candidate_iter = nil
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

local function get_candidates(player, state)
  local candidates = state.build_candidates
  if not candidates then
    local build_distance = math.min(player.build_distance + 0.5, Constants.MAX_DISTANCE)
    candidates = Scanner.find_candidates(
      cache,
      player.surface.name,
      player.position,
      build_distance,
      Constants.MAX_CANDIDATES)
    state.build_candidates = candidates
    state.candidate_iter = nil
  end
  return candidates
end

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

local function try_revive(entity, player)
  local stacks_to_place = to_place(entity.ghost_name)
  for _, stack_to_place in pairs(stacks_to_place) do
    local success = try_revive_with_stack(entity, player, stack_to_place)
    if success then return success end
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

local function try_upgrade(entity, player)
  if entity.type == "underground-belt" and entity.neighbours then
    return try_upgrade_paired_entity(entity, entity.neighbours, player)
  elseif entity.type == "pipe-to-ground" and entity.neighbours[1] and entity.neighbours[1][1] then
    return try_upgrade_paired_entity(entity, entity.neighbours[1][1], player)
  else
    return try_upgrade_single_entity(entity, player)
  end
end

local function try_deconstruct_tile(entity, player)
  local position = entity.position
  return player.mine_tile(entity.surface.get_tile(position.x, position.y))
end

local function try_deconstruct_entity(entity, player)
  return player.mine_entity(entity)
end

local function try_candidate(entry, player)
  if not entry or not entry.action_type or entry.action_type <= ActionTypes.NONE then
    return false
  end

  local entity = entry.entity
  if not entity or not entity.valid then
    return false
  end

  local state = get_player_state(player.index)

  if state.enable_deconstruction then
    if entry.action_type == ActionTypes.DECONSTRUCT then
      return try_deconstruct_entity(entity, player)
    elseif entry.action_type == ActionTypes.DECONSTRUCT_TILE then
      return try_deconstruct_tile(entity, player)
    end
  end

  if state.enable_construction then
    if entry.action_type == ActionTypes.ENTITY_GHOST then
      return try_revive(entity, player)
    elseif state.enable_tiles and entry.action_type == ActionTypes.TILE_GHOST then
      return try_revive(entity, player)
    elseif entry.action_type == ActionTypes.UPGRADE then
      return try_upgrade(entity, player)
    end
  end

  return false
end

local function player_autobuild(player, state)
  local candidates = get_candidates(player, state)

  local candidate
  local remainingActions = state.action_rate or 2 -- default 2
  repeat
    state.candidate_iter, candidate = next(candidates, state.candidate_iter)
    if candidate then
      if try_candidate(candidate, player) then
        remainingActions = remainingActions - 1
      end
    end
  until (not candidate) or (remainingActions == 0)

  if not candidate then
    if not state.last_success then
      state.motionless_updates = -10
    end
    state.build_candidates = nil
    state.last_success = nil
  else
    state.last_success = true
  end
end

local god_controller = defines.controllers.god
local character_controller = defines.controllers.character
local function handle_player_update(player)
  local controller = player.controller_type
  if controller ~= god_controller and controller ~= character_controller then
    -- don't allow spectators or characters awaiting respawn to act
    return
  end

  local state = get_player_state(player.index)
  if not state.enable_construction and not state.enable_destruction then return end
  if player.in_combat then return end

  local updates = state.motionless_updates or 0
  if updates < Constants.UPDATE_THRESHOLD then
    state.motionless_updates = updates + 1
    return
  end

  player_autobuild(player, state)
end

script.on_nth_tick(Constants.UPDATE_PERIOD, function(event)
  for _, player in pairs(game.connected_players) do
    handle_player_update(player)
  end
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.setting ~= "autobuild-action-rate" then
    local state = get_player_state(event.player_index)
    state.action_rate = settings.get_player_settings(event.player_index)[event.setting].value
  end
end)