---@diagnostic disable: undefined-global, undefined-field
-- VF: shim. Engine entry is /lua run vf. AutoRun may still say /lua run vft.
local mq = require('mq')
print('\ay[VF]\ax /lua run vft is retired -- starting \ag/lua run vf\ax.')
mq.cmd('/lua run vf')
