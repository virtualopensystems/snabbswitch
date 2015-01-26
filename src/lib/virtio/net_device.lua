-- Implements virtio-net device


module(...,package.seeall)

local freelist  = require("core.freelist")
local lib       = require("core.lib")
local link      = require("core.link")
local memory    = require("core.memory")
local packet    = require("core.packet")
local timer     = require("core.timer")
local tlb       = require("lib.tlb")
local vq        = require("lib.virtio.virtq")
local ffi       = require("ffi")
local C         = ffi.C
local band      = bit.band
local get_buffers = vq.VirtioVirtq.get_buffers

require("lib.virtio.virtio.h")
require("lib.virtio.virtio_vring_h")

local char_ptr_t = ffi.typeof("char *")
local virtio_net_hdr_size = ffi.sizeof("struct virtio_net_hdr")
local virtio_net_hdr_mrg_rxbuf_size = ffi.sizeof("struct virtio_net_hdr_mrg_rxbuf")
local virtio_net_hdr_mrg_rxbuf_type = ffi.typeof("struct virtio_net_hdr_mrg_rxbuf *")

local invalid_header_id = 0xffff

--[[
   A list of what needs to be implemented in order to fully support
   some of the options.

   - VIRTIO_NET_F_CSUM - enables the SG I/O (resulting in
      multiple chained data buffers in our TX path(self.rxring))
      Required by GSO/TSO/USO. Requires CSUM offload support in the
      HW driver (now intel10g)

   - VIRTIO_NET_F_MRG_RXBUF - enables multiple chained buffers in our RX path
      (self.txring). Also chnages the virtio_net_hdr to virtio_net_hdr_mrg_rxbuf

   - VIRTIO_F_ANY_LAYOUT - the virtio_net_hdr/virtio_net_hdr_mrg_rxbuf is "prepended"
      in the first data buffer instead if provided by a separate descriptor.
      Supported in fairly recent (3.13) Linux kernels

   - VIRTIO_RING_F_INDIRECT_DESC - support indirect buffer descriptors.

   - VIRTIO_NET_F_CTRL_VQ - creates a separate control virt queue

   - VIRTIO_NET_F_MQ - multiple RX/TX queues, usefull for SMP (host/guest).
      Requires VIRTIO_NET_F_CTRL_VQ

--]]
local supported_features = C.VIRTIO_F_ANY_LAYOUT +
                           C.VIRTIO_RING_F_INDIRECT_DESC +
                           C.VIRTIO_NET_F_CTRL_VQ +
                           C.VIRTIO_NET_F_MQ
--[[
   The following offloading flags are also available:
   VIRTIO_NET_F_CSUM
   VIRTIO_NET_F_GUEST_CSUM
   VIRTIO_NET_F_GUEST_TSO4 + VIRTIO_NET_F_GUEST_TSO6 + VIRTIO_NET_F_GUEST_ECN + VIRTIO_NET_F_GUEST_UFO
   VIRTIO_NET_F_HOST_TSO4 + VIRTIO_NET_F_HOST_TSO6 + VIRTIO_NET_F_HOST_ECN + VIRTIO_NET_F_HOST_UFO
]]--

local max_virtq_pairs = 16

VirtioNetDevice = {}

function VirtioNetDevice:new(owner)
   assert(owner)
   local o = {
      owner = owner,
      callfd = {},
      kickfd = {},
      virtq = {},
      rx = {},
      tx = {}
   }

   o = setmetatable(o, {__index = VirtioNetDevice})

   for i = 0, max_virtq_pairs-1 do
      -- TXQ
      o.virtq[2*i] = vq.VirtioVirtq:new()
      o.virtq[2*i].device = o
      -- RXQ
      o.virtq[2*i+1] = vq.VirtioVirtq:new()
      o.virtq[2*i+1].device = o
   end

   self.virtq_pairs = 1
   self.hdr_size = virtio_net_hdr_size

   return o
end

function VirtioNetDevice:poll_vring_receive ()
   -- RX
   self:receive_packets_from_vm()
   self:rx_signal_used()
end

-- Receive all available packets from the virtual machine.
function VirtioNetDevice:receive_packets_from_vm ()
   for i = 0, self.virtq_pairs-1 do
      self.ring_id = 2*i+1
      local virtq = self.virtq[self.ring_id]
      local ops = {
         packet_start = self.rx_packet_start,
         buffer_add   = self.rx_buffer_add,
         packet_end   = self.rx_packet_end
      }
      get_buffers(virtq, 'rx', ops, self.hdr_size)
   end
end

function VirtioNetDevice:rx_packet_start(addr, len)
   local rx_p = packet.allocate()

   return rx_p
end

function VirtioNetDevice:rx_buffer_add(rx_p, addr, len)

   local addr = self:map_from_guest(addr)
   local pointer = ffi.cast(char_ptr_t, addr)

   packet.append(rx_p, pointer, len)
   return len
end

function VirtioNetDevice:rx_packet_end(header_id, total_size, rx_p)
   local l = self.owner.output.tx
   if l then
      link.transmit(l, rx_p)
   else
      debug("droprx", "len", rx_p.length)
      packet.free(rx_p)
   end
   self.virtq[self.ring_id]:put_buffer(header_id, total_size)
end

-- Advance the rx used ring and signal up
function VirtioNetDevice:rx_signal_used()
   for i = 0, self.virtq_pairs-1 do
      self.virtq[2*i+1]:signal_used()
   end
end


function VirtioNetDevice:poll_vring_transmit ()
   -- RX
   self:transmit_packets_to_vm()
   self:tx_signal_used()
end

-- Receive all available packets from the virtual machine.
function VirtioNetDevice:transmit_packets_to_vm ()
   for i = 0, self.virtq_pairs-1 do
      self.ring_id = 2*i
      local virtq = self.virtq[self.ring_id]
      local ops = {
         packet_start = self.tx_packet_start,
         buffer_add   = self.tx_buffer_add,
         packet_end   = self.tx_packet_end
      }
      get_buffers(virtq, 'tx', ops, self.hdr_size)
   end
end

function VirtioNetDevice:tx_packet_start(addr, len)
   local l = self.owner.input.rx
   if link.empty(l) then return nil, nil end
   local tx_p = link.receive(l)

   local tx_header_pointer = ffi.cast(char_ptr_t, self:map_from_guest(addr))
   ffi.fill(tx_header_pointer, self.hdr_size, 0)

   return tx_p
end

function VirtioNetDevice:tx_buffer_add(tx_p, addr, len)

   local addr = self:map_from_guest(addr)
   local pointer = ffi.cast(char_ptr_t, addr)

   assert(tx_p.length<=len)
   ffi.copy(pointer, tx_p.data, tx_p.length)
   return tx_p.length
end

function VirtioNetDevice:tx_packet_end(header_id, total_size, tx_p)
   packet.free(tx_p)
   self.virtq[self.ring_id]:put_buffer(header_id, total_size)
end

-- Advance the rx used ring and signal up
function VirtioNetDevice:tx_signal_used()
   for i = 0, self.virtq_pairs-1 do
      self.virtq[2*i]:signal_used()
   end
end

local pagebits = memory.huge_page_bits

-- Cache of the latest referenced physical page.
function VirtioNetDevice:translate_physical_addr (addr)
   local page = bit.rshift(addr, pagebits)
   if page == self.last_virt_page then
      return addr + self.last_virt_offset
   end
   local phys = memory.virtual_to_physical(addr)
   self.last_virt_page = page
   self.last_virt_offset = phys - addr
   return phys
end

function VirtioNetDevice:map_from_guest (addr)
   local result
   for i = 0, table.getn(self.mem_table) do
      local m = self.mem_table[i]
      if addr >= m.guest and addr < m.guest + m.size then
         if i ~= 0 then
            self.mem_table[i] = self.mem_table[0]
            self.mem_table[0] = m
         end
         result = addr + m.snabb - m.guest
         break
      end
   end
   if not result then
      error("mapping to host address failed" .. tostring(ffi.cast("void*",addr)))
   end
   return result
end

function VirtioNetDevice:map_from_qemu (addr)
   local result = nil
   for i = 0, table.getn(self.mem_table) do
      local m = self.mem_table[i]
      if addr >= m.qemu and addr < m.qemu + m.size then
         result = addr + m.snabb - m.qemu
         break
      end
   end
   if not result then
      error("mapping to host address failed" .. tostring(ffi.cast("void*",addr)))
   end
   return result
end

function VirtioNetDevice:get_features()
   print(string.format("Get features 0x%x\n%s", tonumber(supported_features), get_feature_names(supported_features)))
   return supported_features
end

function VirtioNetDevice:set_features(features)
   print(string.format("Set features 0x%x\n%s", tonumber(features), get_feature_names(features)))
   self.features = features
   if band(self.features, C.VIRTIO_NET_F_MRG_RXBUF) == C.VIRTIO_NET_F_MRG_RXBUF then
      self.hdr_size = virtio_net_hdr_mrg_rxbuf_size
      self.mrg_rxbuf = true
   end
end

function VirtioNetDevice:set_vring_num(idx, num)
   local n = tonumber(num)
   if band(n, n - 1) ~= 0 then
      error("vring_num should be power of 2")
   end

   self.virtq[idx].vring_num = n
   -- update the curent virtq pairs
   self.virtq_pairs = math.max(self.virtq_pairs, math.floor(idx/2)+1)
end

function VirtioNetDevice:set_vring_call(idx, fd)
   self.virtq[idx].callfd = fd
end

function VirtioNetDevice:set_vring_kick(idx, fd)
   self.virtq[idx].kickfd = fd
end

function VirtioNetDevice:set_vring_addr(idx, ring)

   self.virtq[idx].virtq = ring
   self.virtq[idx].avail = tonumber(ring.used.idx)
   self.virtq[idx].used = tonumber(ring.used.idx)
   print(string.format("rxavail = %d rxused = %d", self.virtq[idx].avail, self.virtq[idx].used))
   ring.used.flags = C.VRING_F_NO_NOTIFY
end

function VirtioNetDevice:ready()
   return self.virtq[0].virtq and self.virtq[1].virtq
end

function VirtioNetDevice:set_vring_base(idx, num)
   self.virtq[idx].avail = num
end

function VirtioNetDevice:get_vring_base(idx)
   return self.virtq[idx].avail
end

function VirtioNetDevice:set_mem_table(mem_table)
   self.mem_table = mem_table
end

function VirtioNetDevice:report()
   debug("txavail", self.virtq[0].virtq.avail.idx,
      "txused", self.virtq[0].virtq.used.idx,
      "rxavail", self.virtq[1].virtq.avail.idx,
      "rxused", self.virtq[1].virtq.used.idx)
end

function VirtioNetDevice:rx_buffers()
   return self.vring_transmit_buffers
end

feature_names = {
   [C.VIRTIO_F_NOTIFY_ON_EMPTY]                 = "VIRTIO_F_NOTIFY_ON_EMPTY",
   [C.VIRTIO_RING_F_INDIRECT_DESC]              = "VIRTIO_RING_F_INDIRECT_DESC",
   [C.VIRTIO_RING_F_EVENT_IDX]                  = "VIRTIO_RING_F_EVENT_IDX",

   [C.VIRTIO_F_ANY_LAYOUT]                      = "VIRTIO_F_ANY_LAYOUT",
   [C.VIRTIO_NET_F_CSUM]                        = "VIRTIO_NET_F_CSUM",
   [C.VIRTIO_NET_F_GUEST_CSUM]                  = "VIRTIO_NET_F_GUEST_CSUM",
   [C.VIRTIO_NET_F_GSO]                         = "VIRTIO_NET_F_GSO",
   [C.VIRTIO_NET_F_GUEST_TSO4]                  = "VIRTIO_NET_F_GUEST_TSO4",
   [C.VIRTIO_NET_F_GUEST_TSO6]                  = "VIRTIO_NET_F_GUEST_TSO6",
   [C.VIRTIO_NET_F_GUEST_ECN]                   = "VIRTIO_NET_F_GUEST_ECN",
   [C.VIRTIO_NET_F_GUEST_UFO]                   = "VIRTIO_NET_F_GUEST_UFO",
   [C.VIRTIO_NET_F_HOST_TSO4]                   = "VIRTIO_NET_F_HOST_TSO4",
   [C.VIRTIO_NET_F_HOST_TSO6]                   = "VIRTIO_NET_F_HOST_TSO6",
   [C.VIRTIO_NET_F_HOST_ECN]                    = "VIRTIO_NET_F_HOST_ECN",
   [C.VIRTIO_NET_F_HOST_UFO]                    = "VIRTIO_NET_F_HOST_UFO",
   [C.VIRTIO_NET_F_MRG_RXBUF]                   = "VIRTIO_NET_F_MRG_RXBUF",
   [C.VIRTIO_NET_F_STATUS]                      = "VIRTIO_NET_F_STATUS",
   [C.VIRTIO_NET_F_CTRL_VQ]                     = "VIRTIO_NET_F_CTRL_VQ",
   [C.VIRTIO_NET_F_CTRL_RX]                     = "VIRTIO_NET_F_CTRL_RX",
   [C.VIRTIO_NET_F_CTRL_VLAN]                   = "VIRTIO_NET_F_CTRL_VLAN",
   [C.VIRTIO_NET_F_CTRL_RX_EXTRA]               = "VIRTIO_NET_F_CTRL_RX_EXTRA",
   [C.VIRTIO_NET_F_CTRL_MAC_ADDR]               = "VIRTIO_NET_F_CTRL_MAC_ADDR",
   [C.VIRTIO_NET_F_CTRL_GUEST_OFFLOADS]         = "VIRTIO_NET_F_CTRL_GUEST_OFFLOADS",

   [C.VIRTIO_NET_F_MQ]                          = "VIRTIO_NET_F_MQ"
}

function get_feature_names(bits)
local string = ""
   for mask,name in pairs(feature_names) do
      if (bit.band(bits,mask) == mask) then
         string = string .. " " .. name
      end
   end
   return string
end

function debug (...)
   if _G.developer_debug then print(...) end
end
