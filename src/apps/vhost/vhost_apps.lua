module(...,package.seeall)

local app    = require("core.app")
local buffer = require("core.buffer")
local packet = require("core.packet")
local lib    = require("core.lib")
local vhostclient  = require("apps.vhost.vhost")
local vhostserver  = require("apps.vhost.vhost_server")
local basic_apps = require("apps.basic.basic_apps")

TapVhost = {}

function TapVhost:new (ifname)
   local dev = vhostclient.new(ifname)
   return setmetatable({ dev = dev }, {__index = TapVhost})
end

function TapVhost:pull ()
   self.dev:sync_receive()
   self.dev:sync_transmit()
   local l = self.output.tx
   if l == nil then return end
   while not app.full(l) and self.dev:can_receive() do
      app.transmit(l, self.dev:receive())
   end
   while self.dev:can_add_receive_buffer() do
      self.dev:add_receive_buffer(buffer.allocate())
   end
end

function TapVhost:push ()
   local l = self.input.rx
   if l == nil then return end
   while not app.empty(l) and self.dev:can_transmit() do
      local p = app.receive(l)
      self.dev:transmit(p)
      packet.deref(p)
   end
end

ServerVhost = {}

function ServerVhost:new (sockname)
   local dev = vhostserver.new(sockname)
   return setmetatable({ dev = dev }, {__index = ServerVhost})
end

function ServerVhost:pull ()
   self.dev:sync_receive()
   self.dev:sync_transmit()
   local l = self.output.tx
   if l == nil then return end
   while not app.full(l) and self.dev:can_receive() do
      app.transmit(l, self.dev:receive())
   end
   while self.dev:can_add_receive_buffer() do
      self.dev:add_receive_buffer(buffer.allocate())
   end
end

function ServerVhost:push ()
   local l = self.input.rx
   if l == nil then return end
   while not app.empty(l) and self.dev:can_transmit() do
      local p = app.receive(l)
      self.dev:transmit(p)
      packet.deref(p)
   end
end

function selftest ()
   app.apps.servervhost  = app.new(ServerVhost:new("./vhost-user.sock"))
   app.apps.tapvhost = app.new(TapVhost:new("tap0"))
   app.apps.sink     = app.new(basic_apps.Sink)
   app.connect("servervhost", "out", "tapvhost", "rx")
   app.connect("tapvhost", "tx", "sink", "in")
   app.relink()
   buffer.preallocate(10e5)
   local deadline = lib.timer(10e9)
   repeat app.breathe() until deadline()
   app.report()
end

