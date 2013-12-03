module(...,package.seeall)

function new (sockname)
   local dev = { }
   setmetatable(dev, {__index = getfenv()})
   return dev
end

--- ### Transmit
function sync_transmit (dev)
end

--- ### Receive
function sync_receive (dev)
end
