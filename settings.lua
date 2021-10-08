local settings = {}

table.insert(settings,
    {
        type = "int-setting",
        name = "autobuild-update-period",
        order = "a",
        setting_type = "runtime-global",
        default_value = 10,
        minimum_value = 1,
        maximum_value = 600,
    })

table.insert(settings,
    {
        type = "int-setting",
        name = "autobuild-action-rate",
        order = "b",
        setting_type = "runtime-per-user",
        default_value = 2,
        minimum_value = 1,
        maximum_value = 100,
    })

table.insert(settings,
    {
        type = "int-setting",
        name = "autobuild-update-threshold",
        order = "c",
        setting_type = "runtime-per-user",
        default_value = 1,
        minimum_value = 0,
        maximum_value = 50,
    })

table.insert(settings,
    {
        type = "int-setting",
        name = "autobuild-idle-rebuild",
        order = "d",
        setting_type = "runtime-per-user",
        default_value = 30,
        minimum_value = 1,
        maximum_value = 100,
    })

data:extend(settings)
