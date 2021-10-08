local settings = {}
table.insert(settings,
    {
        type = "int-setting",
        name = "autobuild-action-rate",
        order = "a",
        setting_type = "runtime-per-user",
        default_value = 2,
        minimum_value = 1,
        maximum_value = 100,
    })

data:extend(settings)
