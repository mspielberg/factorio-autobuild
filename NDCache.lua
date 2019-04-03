local NDCache = {}

function NDCache:get(dims)
  local dof = #dims
  local layers = {self.cache}
  local x
  for d=1,dof do
    local key = dims[d]
    x = layers[d][key]
    layers[d+1] = x or {}
  end

  if x then return x end

  x = self.generator(dims)
  layers[dof+1] = x

  for d=dof,1,-1 do
    local key = dims[d]
    layers[d][key] = layers[d+1]
  end

  return x
end

function NDCache:invalidate(dims)
  local t = self.cache
  for i=1,#dims-1 do
    t = t[dims[i]]
    if not t then return end
  end
  t[dims[#dims]] = nil
end

local meta = {
  __index = NDCache,
}

local function restore(self)
  return setmetatable(self, meta)
end

local function new(generator)
  local self = {
    generator = generator,
    cache = {},
  }
  return restore(self)
end

return {
  new = new,
  restore = restore,
}
