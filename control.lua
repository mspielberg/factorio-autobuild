local NDCache = require "NDCache"
local Scanner = require "Scanner"
local ActionTypes = require "ActionTypes"
local Constants = require "Constants"
local HelpFunctions = require "HelpFunctions"
local FlyingText = require "flying_text"

local cache = NDCache.new(Scanner.generator)
local player_state
local cycle_length_in_ticks = tonumber(settings.global["autobuild-cycle-length-in-ticks"].value) or 10

local SUCCESS_DONE_ALL = 1
local SUCCESS_DONE_NOTHING = 2
local SUCCESS_DONE_PARTIALLY = 3
local UNSUCCESS_SKIP = 4

local function get_player_state(player_index)
  local state = player_state[player_index]
  if not state then
    state = {}
    state.enable_tiles = true --default enabled
    state.actions_per_cycle = settings.get_player_settings(player_index)["autobuild-actions-per-cycle"].value
    state.idle_cycles_before_recheck = settings.get_player_settings(player_index)["autobuild-idle-cycles-before-recheck"].value
    state.enable_visual_area = settings.get_player_settings(player_index)["autobuild-enable-visual-area"].value
    state.visual_area_opacity = settings.get_player_settings(player_index)["autobuild-visual-area-opacity"].value
    state.ignore_other_robots = settings.get_player_settings(player_index)["autobuild-ignore-other-robots"].value
    state.build_while_in_combat = settings.get_player_settings(player_index)["autobuild-build-while-in-combat"].value
    state.deconstruct_max_items = settings.get_player_settings(player_index)["autobuild-deconstruct-max-items"].value

    state.last_successful_build_tick = 0

    player_state[player_index] = state
  end
  return state
end

local function change_visual_area(player, state, opacity)

  if state.visual_area_id then
    if rendering.is_valid(state.visual_area_id) then
      rendering.destroy(state.visual_area_id)
    end
    state.visual_area_id = nil
  end

  -- player.print("enable_visual_area ".. (state.enable_visual_area and "true" or "false"))
  -- player.print("opacity ".. (opacity or "nil"))
  -- player.print("player.character "..serpent.block(player.character))
  -- player.print("build_distance "..(state.build_distance or "nil"))

  if not state.enable_visual_area then return end
  if not opacity or opacity <= 0 then return end
  if not player.character then return end
  if not state.build_distance then return end

  local radius = state.build_distance + 0.5

  state.visual_area_id = rendering.draw_rectangle({
    surface = player.surface,
    filled = true,
    draw_on_ground = true,
    color = { r=(opacity/200), g=(opacity/200), b=0, a=(opacity/200) },
    left_top = player.character,
    left_top_offset = { -1*radius, -1*radius },
    right_bottom = player.character,
    right_bottom_offset = { radius, radius },
    players = { player },
  })
end

-- on_character_swapped_event
-- params: event
--   new_unit_number
--   old_unit_number
--   new_character
--   old_character
local function on_character_swapped_event(event)
  -- attach visual area to the new character
  local player = event and event.new_character and event.new_character.player
  if not player then return end
  if not player.index then return end

  local state = get_player_state(player.index)
  if not state.visual_area_id then return end
  if not state.build_distance then return end

  local radius = state.build_distance + 0.5
  if not rendering.is_valid(state.visual_area_id) then
    state.visual_area_id = nil
    return
  end

  local target = rendering.get_left_top(state.visual_area_id)
  if target and target.entity and target.entity.unit_number == event.old_unit_number then
    rendering.set_corners(state.visual_area_id,
        event.new_character, { -1*radius, -1*radius },
        event.new_character, { radius, radius })
  end
end

remote.add_interface("autobuild", { on_character_swapped = on_character_swapped_event } )

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
  -- cleanup
  rendering.clear("autobuild") -- removes all rendering object of this mod
  local construction_toggle_name = "autobuild-shortcut-toggle-construction"
  for _, player in pairs(game.players) do
    if player and player.is_shortcut_available(construction_toggle_name)
              and player.is_shortcut_toggled(construction_toggle_name) then
      player.set_shortcut_toggled(construction_toggle_name, false)
    end
  end
  global.player_state = {}
  cache = NDCache.new(Scanner.generator)
  on_load()
end
script.on_configuration_changed(on_configuration_changed)

local function toggle_enabled_construction(player)
  local state = get_player_state(player.index)
  local enable = not state.enable_construction

  state.enable_construction = enable

  state.build_candidates = nil
  state.candidate_iter = nil

  cache = NDCache.new(Scanner.generator)

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
  local entity = event.entity or event.created_entity
  cache:invalidate(entity_chunk_key(entity))
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
  on_cancelled_deconstruction = entity_changed,

  on_marked_for_upgrade = entity_changed,
  on_cancelled_upgrade = entity_changed,

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

local function force_match(entity, player, including_neutral_force)
  if not entity.force or not entity.force.name then
    return false
  end

  if not player.force or not player.force.name then
    return false
  end

  if entity.force.name == player.force.name then
    return true
  end

  if including_neutral_force and entity.force.name == "neutral" then
    return true
  end

  return false
end

local to_place_cache = {}
local function to_place(entity_name)
  local stacks = to_place_cache[entity_name]
  if not stacks then
    local prototype = game.entity_prototypes[entity_name] or game.tile_prototypes[entity_name]
    stacks = prototype and prototype.items_to_place_this or {}
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
  local inserted = 0
  if player.can_insert {name=name, count=count} then
    inserted = player.insert{name=name, count=count}
  end

  if inserted < count then
    if entity then
      entity.surface.spill_item_stack(entity.position, {name = name, count = count - inserted})
    else
      player.surface.spill_item_stack(player.position, {name = name, count = count - inserted})
    end
  end
end

local function try_revive_with_stack(ghost, player, stack_to_place)
  if player.get_item_count(stack_to_place.name) < stack_to_place.count then
    return UNSUCCESS_SKIP
  end

  if not ghost.valid then
    return UNSUCCESS_SKIP
  end

  if ghost.name == "entity-ghost" and not player.surface.can_place_entity {
      name = ghost.ghost_name,
      position = ghost.position,
      direction = ghost.direction,
      force = ghost.force
    }
  then
    return UNSUCCESS_SKIP
  end

  local items, entity, request_proxy = ghost.revive{
    return_item_request_proxy = true,
    raise_revive = true,
  }
  if not items then
    return UNSUCCESS_SKIP
  end

  for name, count in pairs(items) do
    insert_or_spill(player, entity, name, count)
  end
  player.remove_item(stack_to_place)

  if request_proxy then
    try_insert_requested(entity, request_proxy, player)
  end

  if items ~= nil then
    return SUCCESS_DONE_ALL
  end
  return UNSUCCESS_SKIP
end

local function try_upgrade_with_stack(entity, target_name, player, stack_to_place)

  if not entity.valid then
    return UNSUCCESS_SKIP
  end

  if player.get_item_count(stack_to_place.name) < stack_to_place.count then
    return UNSUCCESS_SKIP
  end

  local new_entity = entity.surface.create_entity{
    name = target_name,
    position = entity.position,
    direction = entity.direction,
    force = entity.force,
    fast_replace = true,
    player = player,
    type = entity.type:find("loader") and entity.loader_type or
      entity.type == "underground-belt" and entity.belt_to_ground_type or
      nil,
    raise_built = true,
  }

  if new_entity then
    player.remove_item(stack_to_place)
    return SUCCESS_DONE_ALL
  end

  return UNSUCCESS_SKIP
end

local function try_revive_entity(entity, player, state)
  if not force_match(entity, player, false) then
    return UNSUCCESS_SKIP
  end

  local stacks_to_place = to_place(entity.ghost_name)
  for _, stack_to_place in pairs(stacks_to_place) do
    if try_revive_with_stack(entity, player, stack_to_place) == SUCCESS_DONE_ALL then
      return SUCCESS_DONE_ALL
    end
  end
  return UNSUCCESS_SKIP
end

local function try_revive_tile(entity, player, state)
  if state.enable_tiles then
    return try_revive_entity(entity, player, state)
  end
  return UNSUCCESS_SKIP
end

local function try_upgrade_single_entity(entity, player)
  local target_proto = entity.get_upgrade_target()
  if not target_proto then
    return UNSUCCESS_SKIP
  end

  local target_name = target_proto.name

  if entity.name == target_name then
    -- same entity name: f.e. upgrade belt to belt
    local direction = entity.get_upgrade_direction()
    -- simply change direction
    if entity.direction ~= direction then
      entity.direction = direction
      entity.cancel_upgrade(player.force, player)
      return SUCCESS_DONE_ALL
    end
  else
    local stacks_to_place = to_place(target_name)
    for _, stack_to_place in pairs(stacks_to_place) do
      if try_upgrade_with_stack(entity, target_name, player, stack_to_place) == SUCCESS_DONE_ALL then
        return SUCCESS_DONE_ALL
      end
    end
  end

  return UNSUCCESS_SKIP
end

local function try_upgrade_paired_entity(entity, other_entity, player)
  if try_upgrade_single_entity(entity, player) == UNSUCCESS_SKIP then
    return UNSUCCESS_SKIP
  end

  if try_upgrade_single_entity(other_entity, player) == UNSUCCESS_SKIP then
    return UNSUCCESS_SKIP
  end

  return SUCCESS_DONE_ALL
end

local function try_upgrade(entity, player, state)
  if not force_match(entity, player, false) then
    return UNSUCCESS_SKIP
  end

  if entity.type == "underground-belt" and entity.neighbours then
    return try_upgrade_paired_entity(entity, entity.neighbours, player)
  elseif entity.type == "pipe-to-ground" and entity.neighbours[1] and entity.neighbours[1][1] then
    return try_upgrade_paired_entity(entity, entity.neighbours[1][1], player)
  else
    return try_upgrade_single_entity(entity, player)
  end
end

local function move_inventories_of_entity_into_players_inventory(player, entity, max_actions, flying_text_infos)

  if not entity.has_items_inside() then
    -- entity has no items inside
    return SUCCESS_DONE_NOTHING
  end

  local max_index = entity.get_max_inventory_index()
  if not max_index then
    -- entity has no inventory
    return SUCCESS_DONE_NOTHING
  end

  if max_actions and max_actions <= 0 then
    return UNSUCCESS_SKIP
  end
  local remaining_actions = max_actions
  local done_something = false

  for index = 1, max_index do
    local inventory = entity.get_inventory(index)
    if inventory then
      for name, count in pairs(inventory.get_contents()) do
        local max_count = count
        if remaining_actions then
          if remaining_actions <= 0 then
            break
          end

          if remaining_actions < count then
            max_count = remaining_actions
            remaining_actions = 0
          else
            remaining_actions = remaining_actions - count
          end
        end

        local stack = { name = name, count = max_count }
        if player.can_insert(stack) then
          local actually_inserted = player.insert(stack)
          if actually_inserted > 0 then
            done_something = true
            stack.count = actually_inserted
            inventory.remove(stack)
            -- HelpFunctions.log_it("moved " .. actually_inserted .." of " .. name)
            flying_text_infos[name] =
            {
              amount = (flying_text_infos[name] and flying_text_infos[name].amount or 0) + actually_inserted,
              total = player.get_item_count(name) or 0
            }
          end

          if actually_inserted < max_count then
            -- not all items could be moved, so stop it here.
            return SUCCESS_DONE_PARTIALLY
          end

        else
          -- could not be inserted
          if done_something then
            -- something was moved before
            return SUCCESS_DONE_PARTIALLY
          end
          return UNSUCCESS_SKIP
        end

      end
    end
  end

  if done_something then
    if remaining_actions and remaining_actions <= 0 then
      return SUCCESS_DONE_PARTIALLY
    end
    return SUCCESS_DONE_ALL
  end
  return SUCCESS_DONE_NOTHING
end

local inserter_types =
{
  ["inserter"] = true,
}

local function move_items_in_inserters_hand_into_players_inventory(player, entity, max_actions, flying_text_infos)
  if not inserter_types[entity.type] then
    -- entity not an inserter
    return SUCCESS_DONE_NOTHING
  end

  local held_stack = entity.held_stack

  if not held_stack then
    return SUCCESS_DONE_NOTHING
  end

  if not held_stack.valid_for_read then
    return SUCCESS_DONE_NOTHING
  end

  if max_actions and max_actions <= 0 then
    return UNSUCCESS_SKIP
  end
  local remaining_actions = max_actions
  local done_something = false

  local name = held_stack.name
  local count = held_stack.count

  local max_count = count
  if remaining_actions then
    if remaining_actions < count then
      max_count = remaining_actions
      remaining_actions = 0
    else
      remaining_actions = remaining_actions - count
    end
  end

  local stack = { name = name, count = max_count }
  if player.can_insert(stack) then
    local actually_inserted = player.insert(stack)
    if actually_inserted > 0 then
      done_something = true
      flying_text_infos[name] =
      {
        amount = (flying_text_infos[name] and flying_text_infos[name].amount or 0) + actually_inserted,
        total = player.get_item_count(name) or 0
      }

      if actually_inserted == max_count then
        held_stack.clear()

      elseif actually_inserted < max_count then
        -- not all items could be moved, so stop it here.
        held_stack.count = max_count - actually_inserted
        return SUCCESS_DONE_PARTIALLY
      end
    end
  else
    -- nothing could be moved
    return UNSUCCESS_SKIP
  end

  if done_something then
    if remaining_actions and remaining_actions <= 0 then
      return SUCCESS_DONE_PARTIALLY
    end
    return SUCCESS_DONE_ALL
  end
  return SUCCESS_DONE_NOTHING
end

local belt_types =
{
  ["transport-belt"] = true,
  ["splitter"] = true,
  ["underground-belt"] = true,
}

local function move_items_on_belt_into_players_inventory(player, entity, max_actions, flying_text_infos)
  if not belt_types[entity.type] then
    -- entity not a belt
    return SUCCESS_DONE_NOTHING
  end

  local max_index = entity.get_max_transport_line_index()

  if not max_index then
    -- entity has no transport lines
    return SUCCESS_DONE_NOTHING
  end

  if max_actions and max_actions <= 0 then
    return UNSUCCESS_SKIP
  end
  local remaining_actions = max_actions
  local done_something = false

  for index = 1, max_index do
    local transport_line = entity.get_transport_line(index)
    if transport_line then
      for name, count in pairs(transport_line.get_contents()) do
        local max_count = count
        if remaining_actions then
          if remaining_actions <= 0 then
            break
          end

          if remaining_actions < count then
            max_count = remaining_actions
            remaining_actions = 0
          else
            remaining_actions = remaining_actions - count
          end
        end

        local stack = { name = name, count = max_count }
        if player.can_insert(stack) then
          local actually_inserted = player.insert(stack)
          if actually_inserted > 0 then
            done_something = true
            stack.count = actually_inserted
            transport_line.remove_item(stack)
            flying_text_infos[name] =
            {
              amount = (flying_text_infos[name] and flying_text_infos[name].amount or 0) + actually_inserted,
              total = player.get_item_count(name) or 0
            }
          end

          if actually_inserted < max_count then
            -- not all items could be moved, so stop it here.
            return SUCCESS_DONE_PARTIALLY
          end

        else
          -- could not be inserted
          if done_something then
            -- something was moved before
            return SUCCESS_DONE_PARTIALLY
          end
          return UNSUCCESS_SKIP
        end

      end
    end
  end

  if done_something then
    if remaining_actions and remaining_actions <= 0 then
      return SUCCESS_DONE_PARTIALLY
    end
    return SUCCESS_DONE_ALL
  end
  return SUCCESS_DONE_NOTHING
end

local function can_insert_into_players_inventory(player, entity)
  if entity.prototype and entity.prototype.mineable_properties and entity.prototype.mineable_properties.minable then
    if entity.prototype.mineable_properties.products then
      for _, product in pairs(entity.prototype.mineable_properties.products) do
        if product.type == "item" and product.amount then
          if not player.can_insert { name = product.name, count = math.floor(product.amount) } then
            -- false if any of the minable products couldn't be inserted
            return false
          end
        end
      end
    end
    return true
  end
  return false
end

local function try_deconstruct_tile(entity, player, state)
  if not force_match(entity, player, true) then
    return UNSUCCESS_SKIP
  end

  if entity.to_be_deconstructed(player.force.name) then
    local position = entity.position
    local tile = entity.surface.get_tile(position.x, position.y)
    if can_insert_into_players_inventory(player, tile) then
      if player.mine_tile(tile) then
        return SUCCESS_DONE_ALL
      end
    end
  end
  return UNSUCCESS_SKIP
end

local function try_deconstruct_entity(entity, player, state)
  if not force_match(entity, player, true) then
    return UNSUCCESS_SKIP
  end

  local flying_text_infos = {}
  local position = { x = entity.position.x, y = entity.position.y }
  local surface = entity.surface

  local max_actions = nil
  if state.deconstruct_max_items > 0 then
    max_actions = state.deconstruct_max_items
  end

  local success_state
  success_state = move_inventories_of_entity_into_players_inventory(player, entity, max_actions, flying_text_infos)
  if success_state == SUCCESS_DONE_ALL or success_state == SUCCESS_DONE_NOTHING then
    success_state = move_items_in_inserters_hand_into_players_inventory(player, entity, max_actions, flying_text_infos)
    if success_state == SUCCESS_DONE_ALL or success_state == SUCCESS_DONE_NOTHING then
      success_state = move_items_on_belt_into_players_inventory(player, entity, max_actions, flying_text_infos)
      if success_state == SUCCESS_DONE_ALL or success_state == SUCCESS_DONE_NOTHING then
        if can_insert_into_players_inventory(player, entity) then
          if player.mine_entity(entity, false) then
            success_state = SUCCESS_DONE_ALL
          else
            success_state = UNSUCCESS_SKIP
          end
        else
          success_state = UNSUCCESS_SKIP
        end
      end
    end
  end

  -- HelpFunctions.log_it("flying_text_infos " .. serpent.block(flying_text_infos))
  FlyingText.create_flying_text_entities(surface, position, flying_text_infos)
  if flying_text_infos and next(flying_text_infos) then
    --something has moved
    player.play_sound({ path = "utility/inventory_move" })
  end

  return success_state
end

local build_actions =
{
  [ActionTypes.DECONSTRUCT] = try_deconstruct_entity,
  [ActionTypes.DECONSTRUCT_TILE] = try_deconstruct_tile,
  [ActionTypes.ENTITY_GHOST] = try_revive_entity,
  [ActionTypes.TILE_GHOST] = try_revive_tile,
  [ActionTypes.UPGRADE] = try_upgrade,
}

local function is_assigned_to_other_robot(entity, action_type, force_name)

  if action_type == ActionTypes.DECONSTRUCT or action_type == ActionTypes.DECONSTRUCT_TILE then
    -- is_registered_for_deconstruction(force) -> boolean 
    -- Is this entity registered for deconstruction with this force? 
    -- If false, it means a construction robot has been dispatched to deconstruct it, 
    -- or it is not marked for deconstruction. 
    -- The complexity is effectively O(1) - it depends on the number of objects targeting this entity which should be small enough.
    return not entity.is_registered_for_deconstruction(force_name or "no_force")

  elseif action_type == ActionTypes.ENTITY_GHOST or action_type == ActionTypes.TILE_GHOST then
    -- is_registered_for_construction() -> boolean 
    -- Is this entity or tile ghost or item request proxy registered for construction? 
    -- If false, it means a construction robot has been dispatched to build the entity, 
    -- or it is not an entity that can be constructed.
    return not entity.is_registered_for_construction()

  elseif action_type == ActionTypes.UPGRADE then
    -- is_registered_for_upgrade() -> boolean
    -- Is this entity registered for upgrade? 
    -- If false, it means a construction robot has been dispatched to upgrade it, 
    -- or it is not marked for upgrade. 
    -- This is worst-case O(N) complexity where N is the current number of things in the upgrade queue.
    return not entity.is_registered_for_upgrade()
  end
  return false
end

local function try_candidate(entry, player, state)
  if not entry then
    return UNSUCCESS_SKIP
  end

  local action_type = entry.action_type
  if not action_type or action_type <= ActionTypes.NONE then
    return UNSUCCESS_SKIP
  end

  local entity = entry.entity
  if not entity or not entity.valid then
    return UNSUCCESS_SKIP
  end

  -- don't check robot assignment, if setting "ignore_other_robots" is enabled, to save on performance
  if not state.ignore_other_robots then
    local force_name = player.force.name

    if is_assigned_to_other_robot(entity, action_type, force_name) then
      return UNSUCCESS_SKIP
    end
  end

  local build_action = build_actions[entry.action_type]
  if build_action then
    return build_action(entity, player, state)
  end

  return UNSUCCESS_SKIP
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
  if state.candidate_iter then
    candidate = candidates[state.candidate_iter]
  else
    state.candidate_iter, candidate = next(candidates)
  end
  local success_state
  local remainingActions = state.actions_per_cycle
  repeat
    if candidate then
      success_state = try_candidate(candidate, player, state)

      if success_state == SUCCESS_DONE_ALL or success_state == SUCCESS_DONE_PARTIALLY then
        remainingActions = remainingActions - 1
        state.last_successful_build_tick = game.tick
      end

      if success_state ~= SUCCESS_DONE_PARTIALLY then
        -- advance to next in list, unless the candidate was handled only partially
        state.candidate_iter, candidate = next(candidates, state.candidate_iter)
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
local function needs_recheck(state)
  -- increment current_cycle
  state.current_cycle = (state.current_cycle or 0) + 1

  -- increment motionless cycle, which gets reset, when player moves.
  state.motionless_cycles = (state.motionless_cycles or 0) + 1

  if force_recheck then
    --if HelpFunctions.check_severity(3) then HelpFunctions.log_it(string.format("cycle: %d: force recheck", state.current_cycle)) end
    return true -- force recheck
  end

  -- always recheck once every 12 (idle_cycles_before_recheck) cycles, regardless of other conditions
  local is_recheck_cycle = (state.current_cycle % state.idle_cycles_before_recheck) == 0
  if is_recheck_cycle then
    --if HelpFunctions.check_severity(4) then HelpFunctions.log_it(string.format("cycle: %d: recheck regular cycle", state.current_cycle)) end
    return true -- recheck cycle
  end

  -- if player is standing still, no recheck
  if state.motionless_cycles >= 1 then
    --if HelpFunctions.check_severity(4) then HelpFunctions.log_it(string.format("cycle: %d: no recheck: not moved recently", state.current_cycle)) end
    return false --no recheck
  end

  -- this is a pause state, which can only be left by the recheck cycle every 12 (idle_cycles_before_recheck) cycles (and if new building candidates are detected)
  -- no recheck, if 5 sec. has been past, without any successful building action.
  if not state.is_building_phase then

    local ticks_since_last_successful_build = game.tick - state.last_successful_build_tick

    if ticks_since_last_successful_build >= 300 then -- 5 sec.
      --if HelpFunctions.check_severity(3) then HelpFunctions.log_it(string.format("cycle: %d: no recheck: not built recently", state.current_cycle)) end
      return false--no recheck
    end
  end

  --if HelpFunctions.check_severity(3) then HelpFunctions.log_it(string.format("cycle: %d: recheck normal", state.current_cycle)) end
  return true
end

local allowed_controllers =
{
  [defines.controllers.god] = true,
  [defines.controllers.character] = true,
}

---comment
---@param player LuaPlayer
local function handle_player_update(player)
  local state = get_player_state(player.index)
  if not state.enable_construction then return end

  if not allowed_controllers[player.controller_type] then
    -- don't allow spectators or characters awaiting respawn to act
    return
  end

  if not state.build_while_in_combat and player.in_combat then
    -- don't build while in combat only when setting is enabled
    return
  end

  if needs_recheck(state) then
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

local function update_cycle(event)
  for _, player in pairs(game.connected_players) do
    handle_player_update(player)
  end
  force_recheck = false
end

---@diagnostic disable-next-line: param-type-mismatch
script.on_nth_tick(cycle_length_in_ticks, update_cycle)

---comment
---@param event EventData.on_runtime_mod_setting_changed
local function on_runtime_mod_setting_changed(event)
  if event.setting == "autobuild-cycle-length-in-ticks" then
    --unregister with old value
---@diagnostic disable-next-line: param-type-mismatch
    script.on_nth_tick(cycle_length_in_ticks, nil)
    cycle_length_in_ticks = tonumber(settings.global[event.setting].value) or 10
    --register with new value
---@diagnostic disable-next-line: param-type-mismatch
    script.on_nth_tick(cycle_length_in_ticks, update_cycle)

  elseif event.setting == "autobuild-log-level" then
    HelpFunctions.log_level = settings.global[event.setting].value

  elseif event.setting == "autobuild-actions-per-cycle" then
    local state = get_player_state(event.player_index)
    state.actions_per_cycle = settings.get_player_settings(event.player_index)[event.setting].value

  elseif event.setting == "autobuild-idle-cycles-before-recheck" then
    local state = get_player_state(event.player_index)
    state.idle_cycles_before_recheck = settings.get_player_settings(event.player_index)[event.setting].value

  elseif event.setting == "autobuild-visual-area-opacity" or event.setting == "autobuild-enable-visual-area" then
    local state = get_player_state(event.player_index)
    state.enable_visual_area = settings.get_player_settings(event.player_index)["autobuild-enable-visual-area"].value
    state.visual_area_opacity = settings.get_player_settings(event.player_index)["autobuild-visual-area-opacity"].value
    local player = game.players[event.player_index]
    change_visual_area(player, state, state.visual_area_opacity)

  elseif event.setting == "autobuild-ignore-other-robots" then
    local state = get_player_state(event.player_index)
    state.ignore_other_robots = settings.get_player_settings(event.player_index)[event.setting].value

  elseif event.setting == "autobuild-build-while-in-combat" then
    local state = get_player_state(event.player_index)
    state.build_while_in_combat = settings.get_player_settings(event.player_index)[event.setting].value

  elseif event.setting == "autobuild-deconstruct-max-items" then
    local state = get_player_state(event.player_index)
    state.deconstruct_max_items = settings.get_player_settings(event.player_index)[event.setting].value

  end

end

script.on_event(defines.events.on_runtime_mod_setting_changed, on_runtime_mod_setting_changed)