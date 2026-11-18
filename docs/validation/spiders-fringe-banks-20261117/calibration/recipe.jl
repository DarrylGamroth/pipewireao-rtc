using YAML
recipe = YAML.load_file(ARGS[1])
append!(recipe["spatial_frequencies"], [
    [radius / 2 * cospi((angle + 0.5) / 8), radius / 2 * sinpi((angle + 0.5) / 8)]
    for radius in (5, 7, 9) for angle in 0:7
])
recipe["branch_modes"]["scc"] = collect(3:114)
YAML.write_file(ARGS[2], recipe)
