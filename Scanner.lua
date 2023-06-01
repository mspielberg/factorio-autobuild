local ActionTypes = require "ActionTypes"
local Constants = require "Constants"
local HelpFunctions = require "HelpFunctions"

local ceil = math.ceil
local floor = math.floor

local Scanner = {}

local land_names_lookup = {}
for _, name in pairs(Constants.LAND_NAMES) do
  land_names_lookup[name] = true
end

local function position_to_key(pos)
  return floor(pos.x) .. "_" .. floor(pos.y)
end

local function filter_and_annotate_entities(entities, existing_land_tiles_by_pos)
  local filtered = {}
  local i = 1

  for _, entity in pairs(entities) do
    if entity.valid then
      local action_type = ActionTypes.get_action_type(entity)
      if action_type > ActionTypes.NONE then

        local skip = false
        if action_type == ActionTypes.TILE_GHOST then
          if land_names_lookup[entity.ghost_name] then
            local key = position_to_key(entity.position)
            if existing_land_tiles_by_pos[key] then
              skip = true
            end
          end
        end

        if not skip then
          filtered[i] =
          {
            entity = entity,
            position = entity.position,
            action_type = action_type
          }
          i = i+1
        end
      end
    end
  end
  return filtered
end

local function generator(dims)
  local surface_name = dims[1]
  local cx           = dims[2]
  local cy           = dims[3]

  local area_tiles = {
    left_top = {
      x = cx * Constants.AREA_SIZE,
      y = cy * Constants.AREA_SIZE,
    },
    right_bottom = {
      x = (1 + cx) * Constants.AREA_SIZE,
      y = (1 + cy) * Constants.AREA_SIZE,
    },
  }
  local land_tiles = game.surfaces[surface_name].find_tiles_filtered
    {
      area = area_tiles,
      name = Constants.LAND_NAMES
    }

  local area_entities = {
    left_top = {
      x = cx * Constants.AREA_SIZE + 0.1,
      y = cy * Constants.AREA_SIZE + 0.1,
    },
    right_bottom = {
      x = (1 + cx) * Constants.AREA_SIZE - 0.1,
      y = (1 + cy) * Constants.AREA_SIZE - 0.1,
    },
  }
  local entities = game.surfaces[surface_name].find_entities_filtered
    {
      area = area_entities
    }

  if HelpFunctions.check_severity(4) then
    local tiles_short = ""
    for _, tile in pairs(land_tiles) do
      tiles_short = tiles_short .." ".. tile.name.."("..tile.position.x.."/"..tile.position.y..")"
    end

    if tiles_short ~= "" then
      HelpFunctions.log_it("found tiles: "..tiles_short)
    end
  end

  if HelpFunctions.check_severity(4) then
    local tile_ghosts_short = ""
    for _, entity in pairs(entities) do
      local action_type = ActionTypes.get_action_type(entity)
      if action_type == ActionTypes.TILE_GHOST then
        tile_ghosts_short = tile_ghosts_short .." ".. entity.ghost_name.."("..entity.position.x.."/"..entity.position.y..")"
      end
    end

    if tile_ghosts_short ~= "" then
      HelpFunctions.log_it("found tile ghosts: "..tile_ghosts_short)
    end
  end

  local existing_land_tiles_by_pos = {}
  for _, land_tile in pairs(land_tiles) do
    local key = position_to_key(land_tile.position)
    existing_land_tiles_by_pos[key] = true
  end

  local filtered_entities = filter_and_annotate_entities(entities, existing_land_tiles_by_pos)

  if HelpFunctions.check_severity(3) then
    HelpFunctions.log_it("generator found ("..#filtered_entities.."/"..#entities..") entities in chunk: "..serpent.line(dims))
  end

  return filtered_entities
end

--- Returns an infinite iterator starting from 0,0 and proceeding in a
--- counterclockwise spiral to the maximum specified radius.
local function spiral(radius)
  local dx, dy = 0, -1
  local x, y = 0, 0
  return function()
    if x > radius then return end
    local ox, oy = x, y
    if x == y or (x < 0 and x == -y) or (x > 0 and x == 1 - y) then
      -- turn a corner
      dx, dy = -dy, dx
    end
    x = x + dx
    y = y + dy
    return ox, oy
  end
end


local function chunk_spiral(position, radius)
  local x1 = floor(position.x / Constants.AREA_SIZE)
  local y1 = floor(position.y / Constants.AREA_SIZE)
  local s = spiral(ceil(radius / Constants.AREA_SIZE))
  return function()
    local x, y = s()
    if not x then return end
    return x1 + x, y1 + y
  end
end

local function annotate_distances(entries, position)
  for i=1,#entries do
    local entry = entries[i]
    entry.distance = HelpFunctions.chebyshev_distance(entry.position, position)
  end
  return entries
end

local function filter_cache_entries(entries, max_distance)
  local filtered = {}
  local i = 1
  for _, entry in pairs(entries) do
    if entry.distance <= max_distance then
      if entry.entity.valid and entry.action_type > ActionTypes.NONE then
        filtered[i] = entry
        i = i + 1
      end
    end
  end
  return filtered
end

local function by_distance(entry1, entry2)
  if entry1.distance < entry2.distance then
    return -1
  elseif entry1.distance > entry2.distance then
    return 1
  end
  return 0
end

local function by_action_type(entry1, entry2)
  if entry1.action_type < entry2.action_type then
    return -1
  elseif entry1.action_type > entry2.action_type then
    return 1
  end
  return 0
end

local function sort_order(entry1, entry2)
  local by_action_type_result = by_action_type(entry1, entry2)
  if by_action_type_result == 0 then
    return by_distance(entry1, entry2) < 0
  end
  return by_action_type_result < 0
end

local function find_candidates(cache, surface, position, distance, max)
  local entries = {}
  local iter = chunk_spiral(position, distance)
  local i = 1

  for cx, cy in iter do
    local unfiltered = cache:get{surface, cx, cy}
    unfiltered = annotate_distances(unfiltered, position)
    local filtered = filter_cache_entries(unfiltered, distance)
    for _, entry in pairs(filtered) do
      entries[i] = entry
      i = i + 1
    end
    if i > max then break end
  end
  table.sort(entries, sort_order)
  return entries
end

local meta = { __index = Scanner }
local function new(cache)
  return setmetatable({cache = cache}, meta)
end

return {
  find_candidates = find_candidates,
  generator = generator,
}
