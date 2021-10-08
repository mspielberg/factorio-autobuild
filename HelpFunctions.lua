
local HelpFunctions = {}

local abs = math.abs
function HelpFunctions.chebyshev_distance(p1, p2)
  if not p1 or not p2 then return 0 end
  local dx = abs(p1.x - p2.x)
  local dy = abs(p1.y - p2.y)
  if dx > dy then
    return dx + dy / 1000
  else
    return dy + dx / 1000
  end
end

return HelpFunctions
