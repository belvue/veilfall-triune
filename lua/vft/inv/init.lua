---@diagnostic disable: undefined-global, undefined-field
-- VF: shim. Inventory entry is /lua run vfi.
local mq = require('mq')
print('\ay[VF]\ax /lua run vft/inv is retired -- starting \ag/lua run vfi\ax.')
mq.cmd('/lua run vfi')
