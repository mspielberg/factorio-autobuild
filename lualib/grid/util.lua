local M = {}

function M.normalize_position(p)
  if p.x and p.y then
    return p
  end
  return {x=p[1], y=p[2]}
end

function M.normalize_bounding_box(bb)
  if not bb.left_top or not bb.right_bottom then
    bb = { left_top = bb[1], right_bottom = bb[2] }
  end
  bb.left_top = M.normalize_position(bb.left_top)
  bb.right_bottom = M.normalize_position(bb.right_bottom)
  return bb
end

function M.chunkxy(r, position)
  return math.floor(position.x/r), math.floor(position.y/r)
end

function M.distance_to_chunk_boundary(res, x, y)
  local dx = x % res
  local dy = y % res
  return math.min(dx, dy, res-dx, res-dy)
end

--[[
  Iterates coordinates separated from px, py by r units measured by Chebyshev distance
  in a scanline pattern (i.e. +x, then +y)
]]
function M.radius_iter(px, py, r)
  local x1, x2 = px-r, px+r
  local y1, y2 = py-r, py+r
  local x, y = x1, y1
  return function()
    if y > y2 then
      return nil
    end
    local ox, oy = x, y
    if x < x2 then
      if y == y1 or y == y2 then
        x = x + 1
      else
        x = x2
      end
    else
      x = x1
      y = y + 1
    end
    return ox, oy
  end
end

return M