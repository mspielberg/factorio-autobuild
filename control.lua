local NDCache = require "NDCache"
local Scanner = require "Scanner"

local CHUNK_SIZE = 32
local MAX_DISTANCE = 128
local MAX_CANDIDATES = 100
local SHORTCUT_NAME = "autobuild-toggle-construction"
local UPDATE_PERIOD = 10
local UPDATE_THRESHOLD = 4

local cache = NDCache.new(Scanner.generator)
local player_state

local function get_player_state(player_index)
  local state = player_state[player_index]
  if not state then
    state = {}
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
  global.ghosts = nil
end
script.on_configuration_changed(on_configuration_changed)

local function set_enabled(player, enable)
  player.set_shortcut_toggled(SHORTCUT_NAME, enable)
  local state = get_player_state(player.index)
  state.enable_construction = enable
  state.enable_deconstruction = enable

  if enable then
    player.print{"autobuild-message.construction-enabled"}
  else
    player.print{"autobuild-message.construction-disabled"}
  end
end

local floor = math.floor
local function entity_chunk_key(entity)
  local position = entity.position
  return {
    entity.surface.name,
    floor(position.x / CHUNK_SIZE),
    floor(position.y / CHUNK_SIZE),
  }
end

local function entity_changed(event)
  cache:invalidate(entity_chunk_key(event.entity))
end

local event_handlers = {
  on_built_entity = function(event)
    local entity = event.created_entity
    local name = entity.name
    if name == "entity-ghost" or name == "tile-ghost" then
      cache:invalidate(entity_chunk_key(entity))
    end
  end,

  on_lua_shortcut = function(event)
    if event.prototype_name ~= SHORTCUT_NAME then return end
    local player = game.players[event.player_index]
    set_enabled(player, not player.is_shortcut_toggled(SHORTCUT_NAME))
  end,

  on_marked_for_deconstruction = entity_changed,

  on_player_changed_position = function(event)
    local state = get_player_state(event.player_index)
    state.motionless_updates = 0
    state.build_candidates = nil
    state.candidate_iter = nil
  end,

  ["autobuild-toggle-construction"] = function(event)
    local player = game.players[event.player_index]
    set_enabled(player, not player.is_shortcut_toggled(SHORTCUT_NAME))
  end,
}

for event_name, handler in pairs (event_handlers) do
  script.on_event(defines.events[event_name] or event_name, handler)
end

local function get_candidates(player, state)
  local candidates = state.build_candidates
  if not candidates then
    local build_distance = math.min(player.build_distance + 0.5, MAX_DISTANCE)
    candidates = Scanner.find_candidates(
      cache,
      player.surface.name,
      player.position,
      build_distance,
      MAX_CANDIDATES)
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

  local is_tile = ghost.name == "tile-ghost"
  local old_tile
  if is_tile then
    local position = ghost.position
    old_tile = {
      old_tile = ghost.surface.get_tile(position.x, position.y).prototype,
      position = position,
    }
  end

  local items, entity, request_proxy = ghost.revive{
    return_item_request_proxy = true,
    raise_revive = true,
  }
  if not items then return false end

  for name, count in pairs(items) do
    insert_or_spill(player, entity, name, count)
  end
  if is_tile then
    script.raise_event(
      defines.events.on_player_built_tile,
      {
        player_index = player.index,
        surface_index = player.surface.index,
        tiles = { old_tile },
        item = game.item_prototypes[stack_to_place.name],
        revived = true,
        stack = stack_to_place,
      }
    )
  else
    script.raise_event(
      defines.events.on_built_entity,
      {
        player_index = player.index,
        revived = true,
        created_entity = entity,
        stack = stack_to_place,
      }
    )
  end

  player.remove_item(stack_to_place)

  if request_proxy then
    try_insert_requested(entity, request_proxy, player)
  end

  return items ~= nil
end

local function try_revive(entity, player)
  local stacks_to_place = to_place(entity.ghost_name)
  for _, stack_to_place in pairs(stacks_to_place) do
    local success = try_revive_with_stack(entity, player, stack_to_place)
    if success then return success end
  end
end

local function try_deconstruct(entity, player)
  if entity.name == "deconstructible-tile-proxy" then
    local position = entity.position
    return player.mine_tile(entity.surface.get_tile(position.x, position.y))
  else
    return player.mine_entity(entity)
  end
end

local function try_candidate(entity, player)
  local state = get_player_state(player.index)
  if entity.valid then
    if state.enable_deconstruction and entity.to_be_deconstructed(player.force) then
      return try_deconstruct(entity, player)
    elseif state.enable_construction then
      local entity_type = entity.type
      if entity_type == "entity-ghost" or entity_type == "tile-ghost" then
        return try_revive(entity, player)
      else
        return false
      end
    end
  end
end

local function player_autobuild(player, state)
  local candidates = get_candidates(player, state)

  local candidate
  repeat
    state.candidate_iter, candidate = next(candidates, state.candidate_iter)
  until (not candidate) or try_candidate(candidate, player)

  if not candidate then
    if not state.one_success then
      state.motionless_updates = -10
    end
    state.build_candidates = nil
    state.one_success = nil
  else
    state.one_success = true
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
  if updates < UPDATE_THRESHOLD then
    state.motionless_updates = updates + 1
    return
  end

  player_autobuild(player, state)
end

local function gc_filter(entity)
  local name = entity.name
  return name == "entity-ghost"
    or name == "tile-ghost"
    or entity.to_be_deconstructed(entity.force)
end

script.on_nth_tick(UPDATE_PERIOD, function(event)
  for _, player in pairs(game.connected_players) do
    handle_player_update(player)
  end
end)