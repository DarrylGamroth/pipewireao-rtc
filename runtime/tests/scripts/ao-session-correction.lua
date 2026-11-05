-- Keep correction admission cases in a separate native event-dispatcher run.
local _, chunk = package.searchers [2] ("../ao-session-hooks")
assert (type (chunk) == "function", "Session hook test script was not found")
debug.setupvalue (chunk, 1, _ENV)
chunk ("correction")
