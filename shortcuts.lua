data:extend{
  {
    type = "shortcut",
    name = "autobuild-shortcut-toggle-construction",
    order = "c[toggles]-c[autobuild]",
    action = "lua",
    toggleable = true,
    localised_name = {"autobuild-shortcut.autobuild-shortcut-toggle-construction"},
    icon =
    {
      filename = "__autobuild__/graphics/wrench-x32.png",
      priority = "extra-high-no-scale",
      size = 32,
      scale = 1,
      flags = {"icon"}
    },
    small_icon =
    {
      filename = "__autobuild__/graphics/wrench-x24.png",
      priority = "extra-high-no-scale",
      size = 24,
      scale = 1,
      flags = {"icon"}
    },
    disabled_icon =
    {
      filename = "__autobuild__/graphics/wrench-x32-white.png",
      priority = "extra-high-no-scale",
      size = 32,
      scale = 1,
      flags = {"icon"}
    },
    disabled_small_icon =
    {
      filename = "__autobuild__/graphics/wrench-x24-white.png",
      priority = "extra-high-no-scale",
      size = 24,
      scale = 1,
      flags = {"icon"}
    },
  },
}
