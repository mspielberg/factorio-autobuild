local util = require "lualib.grid.util"

local M = {}

--- a set of entities stored by chunk
-- A chunk is a list of entries, with each entry containing an entity
-- reference, position of that entity, and entity bounding box.
-- Chunks are stored by x,y coordinate in chunks_by_xy, and in arbitrary
-- order in the list all_chunks.
local Grid = {}

local function add_chunk(self, cx, cy)
  local id = #self.all_chunks + 1
  local chunk = { id = id, n = 0 }
  local cbxy = self.chunks_by_xy
  local col = cbxy[cx]
  if not col then
    col = {}
    cbxy[cx] = col
  end
  col[cy] = chunk
  self.all_chunks[id] = { x = cx, y = cy, chunk = chunk }
  return chunk
end

function Grid:migrate()
  if self.version == 2 then return end
  self.resolution = self[1]
  self.chunks_by_xy = self[2]
  self[1] = nil
  self[2] = nil

  self.all_chunks = {}
  local id = 0
  for cx, col in pairs(self.chunks_by_xy) do
    for cy, chunk in pairs(col) do
      chunk.n = #chunk
      id = id + 1
      chunk.id = id
      self.all_chunks[chunk.id] = { x = cx, y = cy, chunk = chunk }
    end
  end

  self.version = 2
end

local function get_chunk(self, cx, cy, create)
  local col = self.chunks_by_xy[cx]
  local c = col and col[cy]
  if not c and create then
    c = add_chunk(self, cx, cy)
  end
  return c
end

function Grid:insert(entity)
  local p = entity.position
  local cx, cy = util.chunkxy(self.resolution, p)
  local c = get_chunk(self, cx, cy, true)
  local i = c.n + 1
  c[i] = {
    entity = entity,
    position = entity.position,
    bounding_box = entity.bounding_box,
    distance = nil, -- distance used in nearest_neighbors
  }
  c.n = i
end

local function remove_chunk(self, cx, cy, c)
  local all_chunks = self.all_chunks
  local l = #all_chunks
  all_chunks[l].id = c.id
  all_chunks[c.id] = all_chunks[l]
  all_chunks[l] = nil

  local cbxy = self.chunks_by_xy
  cbxy[cx][cy] = nil
  if not next(cbxy[cx]) then
    cbxy[cx] = nil
  end
end

-- @returns true if an entire empty chunk was deleted
function delete0(self, cx, cy, index)
  local c = get_chunk(self, cx, cy)
  if not c then return end

  local l = c.n
  if l == 1 then
    remove_chunk(self, cx, cy, c)
  else
    c[index] = c[l]
    c[l] = nil
    c.n = c.n - 1
  end
end

function Grid:delete(entity)
  local p = entity.position
  local cx, cy = util.chunkxy(self.resolution, p)
  local c = get_chunk(self, cx, cy)
  if not c then
    return false
  end

  local index
  for i=1,c.n do
    if c[i].entity == entity then
      index = i
      break
    end
  end


  if index then
    delete0(self, cx, cy, index)
    return true
  end
  return false
end

local function intersects(a1, a2)
  return not(a1.left_top.x > a2.right_bottom.x
    or a1.left_top.y > a2.right_bottom.y
    or a1.right_bottom.x < a2.left_top.x
    or a1.right_bottom.y < a2.left_top.y)
end

function Grid:search(area)
  area = util.normalize_bounding_box(area)
  local res = self.resolution
  local cx1, cy1 = util.chunkxy(res, area.left_top)
  local cx2, cy2 = util.chunkxy(res, area.right_bottom)
  local out = {}
  for cx=cx1,cx2+1 do
    for cy=cy1,cy2+1 do
      local c = get_chunk(self, cx, cy)
      if c then
        for i=1,c.n do
          local entity = c[i].entity
          if entity.valid then
            if intersects(area, entry.bounding_box) then
              out[#out+1] = entity
            end
          else
            delete0(self, cx, cy, i)
          end
        end
      end
    end
  end
  return out
end

local function distance2(p1, p2)
  local dx = p1.x - p2.x
  local dy = p1.y - p2.y
  return dx * dx + dy * dy
end

local abs = math.abs
local max = math.max
local function distance_chebyshev(p1, p2)
  local dx = abs(p1.x - p2.x)
  local dy = abs(p1.y - p2.y)
  if dx > dy then
    return dx + dy / 1000
  else
    return dy + dx / 1000
  end
end

local function ascending_by_distance(a, b)
  return a.distance < b.distance
end

local function extract_entities(entries)
  for i=1,#entries do
    entries[i] = entries[i].entity
  end
  return entries
end

function Grid:nearest_neighbors(position, k, max_distance)
  position = util.normalize_position(position)
  local res = self.resolution
  local from_boundary =
    util.distance_to_chunk_boundary(res, position.x, position.y)
  local pcx, pcy = util.chunkxy(res, position)
  local candidates = {}
  local ci = 1
  local max_chunk_radius = max_distance <= from_boundary and 0
    or math.ceil(max_distance / res)
  for cr=0,max_chunk_radius do
    for cx, cy in util.radius_iter(pcx, pcy, cr) do
      local c = get_chunk(self, cx, cy)
      if c then
        for i=1,c.n do
          local entry = c[i]
          local d = distance_chebyshev(position, entry.position)
          if d <= max_distance then
            if entry.entity.valid then
              entry.distance = d
              candidates[ci] = entry
              ci = ci + 1
            else
              delete0(self, cx, cy, i)
            end
          end
        end
      end
    end
    if ci > k then
      break
    end
  end

  table.sort(candidates, ascending_by_distance)
  for i=k+1,ci do
    candidates[i] = nil
  end
  return extract_entities(candidates)
end

local function next_chunk(self)
  local iter = self.all_chunks_iter or 1
  local all_chunks = self.all_chunks
  local c = all_chunks[iter]
  if c then
    self.all_chunks_iter = iter + 1
    return c.x, c.y, c.chunk
  end

  c = all_chunks[1]
  if c then
    -- restart from first chunk
    self.all_chunks_iter = 2
    return c.x, c.y, c.chunk
  else
    -- grid is empty
    return nil
  end
end

local meta = {
  __index = Grid,
}

function Grid:gc(filter)
  local cx, cy, chunk = next_chunk(self)
  if chunk then
    local to_delete = {}
    for i=1,chunk.n do
      if not chunk[i].entity.valid or not filter(chunk[i].entity) then
        to_delete[#to_delete+1] = i
      end
    end
    for i=1,#to_delete do
      delete0(self, cx, cy, to_delete[i])
    end
  end
end

function M.new(resolution)
  resolution = resolution or 32
  local self = {
    resolution      = resolution,
    chunks_by_xy    = {}, -- indexed by [cx][cy]
    all_chunks      = {}, -- flat array
    all_chunks_iter = 1,
  }
  return M.restore(self)
end

function M.restore(self)
  return setmetatable(self, meta)
end

return M