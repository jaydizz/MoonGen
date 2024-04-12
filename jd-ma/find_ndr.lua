local mg     = require "moongen"
local memory = require "memory"
local device = require "device"
local ts     = require "timestamping"
local filter = require "filter"
local hist   = require "histogram"
local stats  = require "stats"
local timer  = require "timer"
local arp    = require "proto.arp"
local log    = require "log"
local dpdkc   = require "dpdkc"
local limiter = require "software-ratecontrol"
local timer = require "timer"
local inspect = require('inspect')
local units = "rateparser"
-- set addresses here
local DST_MAC		= "f8:f2:1e:46:2c:f0" -- resolved via ARP on GW_IP or DST_IP, can be overriden with a string here
local SRC_IP_BASE	= "10.0.0.10" -- actual address will be SRC_IP_BASE + random(0, flows)
local DST_IP		= "48.0.0.1"
local SRC_PORT		= 1234
local DST_PORT		= 319

-- answer ARP requests for this IP on the rx port
-- change this if benchmarking something like a NAT device
local RX_IP		= DST_IP
-- used to resolve DST_MAC
local GW_IP		= DST_IP
-- used as source IP to resolve GW_IP to DST_MAC
local ARP_IP	= SRC_IP_BASE

function configure(parser)
	parser:description("Generates UDP traffic and measure latencies. Edit the source to modify constants like IPs.")
	parser:argument("txDev", "Device to transmit from."):convert(tonumber)
	parser:argument("rxDev", "Device to receive from."):convert(tonumber)
	parser:option("-r --rate", "Start Rate for Search"):default("10kp/s")
	parser:option("-e --endrate", "End Rate for Search"):default("14.5kp/s")
	parser:option("-d --droprate", "Acceptable Droprate in percent"):default("1")
	parser:option("-f --flows", "Number of flows (randomized source IP)."):default(4):convert(tonumber)
	parser:option("-s --size", "Packet size."):default(60):convert(tonumber)
	parser:option("-n --threads", "Number of Threads to use"):default(1):convert(tonumber)
	parser:option("-t --time", "Time in seconds"):default(120):convert(tonumber)
end

DroppedPackets = false


function master(args)
	local low = units.parse_rate(args.rate)
	local high   = units.parse_rate(args.endrate)
	
	local testRate
	while (testRate ~= high) and (testRate ~= low) do
		testRate = math.floor((high - low)/2)
		test(args, testRate)
		if DroppedPackets then
			high = testRate
			DroppePackets = false
		else
			low = testRate
		end
	end
	log:info("%s", testRate)
end

function test(args, rate)
	-- Setup Devices
	txDev = device.config{port = args.txDev, rxQueues = args.threads , txQueues = args.threads}
	rxDev = device.config{port = args.rxDev, rxQueues = args.threads , txQueues = args.threads}
	-- Wait for links to come up.
	device.waitForLinks()
	
	

	-- setup rate-limiter... we have to rely on software ratelimiting here... sadly. 
	-- max 1kpps timestamping traffic timestamping
	--txDev:setRate(rate)
	log:warn("%s", rate)
	--stats.startStatsTask{txDevices = {txDev}}
	
	-- Start Counter Thread first to not miss any packets.
	mg.startTask("ctrSlave", txDev, rxDev, args.time)
	
	-- Create Rate-limiters for each thread!
	-- Since the hardware-rate-limiter fails for small packet rates, we will use a sofware-ratelimiter for these. 
	for i = 1, args.threads do
		local txQueue
		if ( rate < 100 ) 
		then
			txQueue = limiter:new(txDev:getTxQueue(i - 1), "cbr", 8000 * args.size / (rate / args.threads))
			log:info("Using Software Rate-Limiter")
		else 
			txDev:setRate(rate)
			txQueue = txDev:getTxQueue(i - 1)
			log:info("Using HW Rate-Limiter")
		end

		mg.startTask("loadSlave", txQueue, rxDev, args.size, args.flows, args.time)
	end

	mg.waitForTasks()
end

local function fillUdpPacket(buf, len)
	buf:getUdpPacket():fill{
		ethSrc = queue,
		ethDst = DST_MAC,
		ip4Src = SRC_IP,
		ip4Dst = DST_IP,
		udpSrc = SRC_PORT,
		udpDst = DST_PORT,
		pktLength = len
	}
end

function ctrSlave(txDev, rxDev, time)
	local rxCtr = stats:newDevRxCounter(rxDev, "plain")
	local txCtr = stats:newDevTxCounter(txDev, "plain")
	-- runtime timer
        local runtime = nil
        if ( time > 0 ) then
                runtime = timer:new(time)
        end
	mg.sleepMillis(250)
	while mg.running() and (not runtime or runtime:running()) do
		txCtr:update()
		rxCtr:update()
	end
	mg.sleepMillis(250)
	-- Wait for any packets in transit. 
	txCtr:finalize(500)
	rxCtr:finalize(500)
	-- Get latest stats
	local _, _, _, rxStats = rxCtr:getStats()
	local _, _, _, txStats = txCtr:getStats()
	if rxStats < txStats then
		log:warn("In: %s, Out: %s, dropped %s ( %.2f %%) packets", rxStats, txStats, (txStats - rxStats), (txStats - rxStats)/txStats*100)
		DroppedPackets = true
	end

end

function loadSlave(queue, rxDev, size, flows, time)
	local mempool = memory.createMemPool(function(buf)
		fillUdpPacket(buf, size)
	end)
	local bufs = mempool:bufArray()
	local counter = 0
	local baseIP = parseIPAddress(SRC_IP_BASE)
	-- runtime timer
        local runtime = nil
        if ( time > 0 ) then
                runtime = timer:new(time)
        end

	while mg.running() and ( not runtime or runtime:running()) do
		bufs:alloc(size)
		for i, buf in ipairs(bufs) do
			local pkt = buf:getUdpPacket()
			pkt.ip4.src:set(baseIP + counter)
			counter = incAndWrap(counter, flows)
		end
		-- UDP checksums are optional, so using just IPv4 checksums would be sufficient here
		bufs:offloadUdpChecksums()
		queue:send(bufs)
	end
	if queue.stop then
                queue:stop()
        end

end

