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
        name = "autobuild-move-latency",
        order = "c",
        setting_type = "runtime-per-user",
        default_value = 0,
        minimum_value = 0,
        maximum_value = 50,
    })

table.insert(settings,
    {
        type = "int-setting",
        name = "autobuild-move-threshold",
        order = "d",
        setting_type = "runtime-per-user",
        default_value = 0,
        minimum_value = 0,
        maximum_value = 100,
    })

table.insert(settings,
    {
        type = "int-setting",
        name = "autobuild-idle-cycles-before-recheck",
        order = "e",
        setting_type = "runtime-per-user",
        default_value = 12,
        minimum_value = 1,
        maximum_value = 100,
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
