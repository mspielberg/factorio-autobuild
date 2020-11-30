local CHUNK_SIZE = 32
local RECT_RADIUS = 16

local Scanner = {}

local function filter_entities(entities)
  local filtered = {}
  local i = 1
  for _, entity in pairs(entities) do
    if entity.valid then
      local name = entity.name
      if name == "entity-ghost"
      or name == "tile-ghost"
      or entity.to_be_deconstructed(entity.force)
      or entity.to_be_upgraded() then
        filtered[i] = entity
        i = i + 1
      end
    end
  end
  return filtered
end

local function annotate_entities(entities)
  for i=1,#entities do
    local entity = entities[i]
    local name = entity.name
    entities[i] = {
      entity = entity,
      position = entity.position,
      is_ghost = name == "entity-ghost" or name == "tile-ghost",
    }
  end
  return entities
end

local function generator(dims)
  local surface_name = dims[1]
  local cx           = dims[2]
  local cy           = dims[3]
  local area = {
    left_top = {
      x = cx * CHUNK_SIZE + 0.1,
      y = cy * CHUNK_SIZE + 0.1,
    },
    right_bottom = {
      x = (1 + cx) * CHUNK_SIZE - 0.1,
      y = (1 + cy) * CHUNK_SIZE - 0.1,
    },
  }

  local entities = game.surfaces[surface_name].find_entities(area)

  local filtered = annotate_entities(filter_entities(entities))
  --log("generator found ("..#filtered.."/"..#entities..") in chunk: "..serpent.line(dims))
  return filtered
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

local ceil = math.ceil
local floor = math.floor
local function chunk_spiral(position, radius)
  local x1 = floor(position.x / CHUNK_SIZE)
  local y1 = floor(position.y / CHUNK_SIZE)
  local s = spiral(ceil(radius / CHUNK_SIZE))
  return function()
    local x, y = s()
    if not x then return end
    return x1 + x, y1 + y
  end
end


local abs = math.abs
local function chebyshev_distance(p1, p2)
  local dx = abs(p1.x - p2.x)
  local dy = abs(p1.y - p2.y)
  if dx > dy then
    return dx + dy / 1000
  else
    return dy + dx / 1000
  end
end

local function annotate_distances(entries, position)
  for i=1,#entries do
    local entry = entries[i]
    entry.distance = chebyshev_distance(entry.position, position)
  end
  return entries
end

local function filter_cache_entries(entries, max_distance)
  local filtered = {}
  local i = 1
  for _, entry in pairs(entries) do
    if entry.distance <= max_distance then
      local entity = entry.entity
      if entity.valid
      and (entry.is_ghost
           or entity.to_be_deconstructed(entity.force)
           or entity.to_be_upgraded()) then
        filtered[i] = entry
        i = i + 1
      end
    end
  end
  return filtered
end

local function by_distance(entry1, entry2)
  return entry1.distance < entry2.distance
end

local function extract_entities(entries)
  for i=1,#entries do
    entries[i] = entries[i].entity
  end
  return entries
end

local function find_candidates(cache, surface, position, distance, max)
  local out = {}
  local iter = chunk_spiral(position, distance)
  local i = 1
  for cx, cy in iter do
    local entries = cache:get{surface, cx, cy}
    annotate_distances(entries, position)
    local filtered = filter_cache_entries(entries, distance)
    for _, entry in pairs(filtered) do
      out[i] = entry
      i = i + 1
    end
    if i > max then break end
  end
  table.sort(out, by_distance)
  return extract_entities(out)
end

local meta = { __index = Scanner }
local function new(cache)
  return setmetatable({cache = cache}, meta)
end

return {
  find_candidates = find_candidates,
  generator = generator,
}
