-- sabot.t
--
-- bindings for sabot/bullet

local modutils = require("core/module.t")

local m = {}

terralib.linklibrary("sabot")
local sabot_ = terralib.includec("sabot.h")
local sabot_c = {}

modutils.reexport_without_prefix(sabot_, "sb_", sabot_c)

m.C = sabot_c

return m
