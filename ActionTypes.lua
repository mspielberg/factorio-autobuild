
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
  elseif entity.to_be_deconstructed(entity.force) then
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

return ActionTypes
