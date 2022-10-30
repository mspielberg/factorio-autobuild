
-- action type with prio value

local ActionTypes = {
  NONE = 0,
  DECONSTRUCT = 1,
  ENTITY_GHOST = 2,
  UPGRADE = 3,
  TILE_GHOST = 4,
  DECONSTRUCT_TILE = 5,
}

function ActionTypes.get_action_type(entity)
  if not entity.valid then
    return ActionTypes.NONE
  end

  local entity_name = entity.name

  if entity_name == "entity-ghost" then
    return ActionTypes.ENTITY_GHOST
  elseif entity.to_be_deconstructed() then
    if entity_name == "deconstructible-tile-proxy" then
      return ActionTypes.DECONSTRUCT_TILE
    else
      return ActionTypes.DECONSTRUCT
    end
  elseif entity.to_be_upgraded() then
    return ActionTypes.UPGRADE
  elseif entity_name == "tile-ghost" then
    return ActionTypes.TILE_GHOST
  end
  return ActionTypes.NONE
end

function ActionTypes.get_action_verb(action_type)
  if action_type == ActionTypes.NONE then
    return ""
  elseif action_type == ActionTypes.ENTITY_GHOST then
    return "built entity"
  elseif action_type == ActionTypes.TILE_GHOST then
    return "built tile"
  elseif action_type == ActionTypes.DECONSTRUCT then
    return "deconstructed entity"
  elseif action_type == ActionTypes.DECONSTRUCT_TILE then
    return "deconstructed tile"
  elseif action_type == ActionTypes.UPGRADE then
    return "upgraded entity"
  end
end

return ActionTypes
