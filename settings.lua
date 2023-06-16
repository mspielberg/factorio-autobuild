local settings = {}

table.insert(settings,
    {
        type = "int-setting",
        name = "autobuild-cycle-length-in-ticks",
        order = "a",
        setting_type = "runtime-global",
        default_value = 10,  --1/6 sec.
        minimum_value = 1,
        maximum_value = 600, --10sec.
    })

table.insert(settings,
    {
        type = "int-setting",
        name = "autobuild-actions-per-cycle",
        order = "b",
        setting_type = "runtime-per-user",
        default_value = 2,
        minimum_value = 1,
        maximum_value = 100,
    })


table.insert(settings,
    {
        type = "int-setting",
        name = "autobuild-idle-cycles-before-recheck",
        order = "c",
        setting_type = "runtime-per-user",
        default_value = 12,
        minimum_value = 1,
        maximum_value = 100,
    })

table.insert(settings,
    {
        type = "bool-setting",
        name = "autobuild-enable-visual-area",
        order = "da",
        setting_type = "runtime-per-user",
        default_value = true,
    })

table.insert(settings,
    {
        type = "int-setting",
        name = "autobuild-visual-area-opacity",
        order = "db",
        setting_type = "runtime-per-user",
        default_value = 20,
        minimum_value = 0,
        maximum_value = 100,
    })

table.insert(settings,
    {
        type = "bool-setting",
        name = "autobuild-ignore-other-robots",
        order = "ea",
        setting_type = "runtime-per-user",
        default_value = false,
    })

table.insert(settings,
    {
        type = "bool-setting",
        name = "autobuild-build-while-in-combat",
        order = "eb",
        setting_type = "runtime-per-user",
        default_value = false,
    })

table.insert(settings,
    {
        type = "int-setting",
        name = "autobuild-deconstruct-max-items",
        order = "ec",
        setting_type = "runtime-per-user",
        default_value = 0,
    })

table.insert(settings,
    {
        type = "int-setting",
        name = "autobuild-log-level",
        order = "z",
        setting_type = "runtime-global",
        default_value = 0,
        minimum_value = 0,
        maximum_value = 5,
    })

data:extend(settings)
