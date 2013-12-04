module(...,package.seeall)

local ffi = require("ffi")
local C = ffi.C
ffi.cdef [[
void* new_vhost_server(const char* path);
int end_vhost_server(void* vhost_server);
int poll_vhost_server(void* vhost_server);
]]

function new (sockname)
   local vhost_server = C.new_vhost_server(sockname)
   local dev = { vhost_server = vhost_server }
   
   setmetatable(dev, {__index = getfenv()})
   return dev
end

--- ### Transmit
function sync_transmit (dev)
end

--- ### Receive
function sync_receive (dev)
	-- poll control server
	C.poll_vhost_server(dev.vhost_server)
end
