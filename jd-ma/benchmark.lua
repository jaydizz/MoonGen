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
local rateparser = require "rateparser"

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
	parser:option("-r --rate", "Transmit rate in Mbit/s."):default(10000)
	parser:option("-f --flows", "Number of flows (randomized source IP)."):default(20):convert(tonumber)
	parser:option("-s --size", "Packet size."):default(60):convert(tonumber)
	parser:option("-n --threads", "Number of Threads to use"):default(1):convert(tonumber)
	parser:option("-t --time", "Time in seconds"):default(120):convert(tonumber)
	parser:option("-l --limiter", "Ratelimiter to use"):default("software")
end

function master(args)
	-- Setup Devices
	txDev = device.config{port = args.txDev, rxQueues = args.threads + 2, txQueues = args.threads + 2}
	rxDev = device.config{port = args.rxDev, rxQueues = args.threads + 2, txQueues = args.threads + 2}
	-- Wait for links to come up.
	device.waitForLinks()
	
	

	-- setup rate-limiter... we have to rely on software ratelimiting here... sadly. 
	-- max 1kpps timestamping traffic timestamping
	local rate = rateparser.parse_rate(args.rate, args.size + 4 )
	--txDev:setRate(rate)
	log:warn("%s", rate)
	--stats.startStatsTask{txDevices = {txDev}}
	
	-- Start Counter Thread first to not miss any packets.
	mg.startTask("ctrSlave", txDev, rxDev, args.time)
	
	-- Create Rate-limiters for each thread!
	-- Since the hardware-rate-limiter fails for small packet rates, we will use a sofware-ratelimiter for these. 
	for i = 1, args.threads do
		local txQueue
		if ( rate < 500 or args.limiter == "software") 
		then
			txQueue = limiter:new(txDev:getTxQueue(i - 1), "cbr", 8000 * (args.size + 4)/ (rate / args.threads))
			log:info("Using Software Rate-Limiter")
		else 
			txDev:setRate(rate)
			txQueue = txDev:getTxQueue(i - 1)
			log:info("Using HW Rate-Limiter")
		end

		mg.startTask("loadSlave", txQueue, rxDev, args.size, args.flows, args.time)
	end

	mg.startTask("timerSlave", txDev:getTxQueue( 2 ), rxDev:getRxQueue( 2 ), args.size, args.flows, args.time)
	--arp.startArpTask{
	--	-- run ARP on both ports
	--	{ rxQueue = rxDev:getRxQueue(2), txQueue = rxDev:getTxQueue(2), ips = RX_IP },
	--	-- we need an IP address to do ARP requests on this interface
	--	{ rxQueue = txDev:getRxQueue(2), txQueue = txDev:getTxQueue(2), ips = ARP_IP }
	--}
	mg.waitForTasks()
	local rxStats = rxDev:getStats() 
	log:info("ipacktes: " .. tostring(rxStats.ipackets))
        log:info("opacktes: " .. tostring(rxStats.opackets))
        log:info("ibytes: " .. tostring(rxStats.ibytes))
        log:info("obytes: " .. tostring(rxStats.obytes))
        log:info("imissed: " .. tostring(rxStats.imissed))
        log:info("ierrors: " .. tostring(rxStats.ierrors))
        log:info("oerrors: " .. tostring(rxStats.oerrors))
        log:info("rx_nombuf: " .. tostring(rxStats.rx_nombuf))

end

local function fillUdpPacket(buf, len)
	buf:getUdpPacket():fill{
		ethSrc = queue,
		ethDst = DST_MAC,
		ip4Src = SRC_IP,
		ip4Dst = "48.0.0.10",
		udpSrc = SRC_PORT,
		udpDst = DST_PORT,
		pktLength = len
	}
end

local function doArp()
	if not DST_MAC then
		log:info("Performing ARP lookup on %s", GW_IP)
		DST_MAC = arp.blockingLookup(GW_IP, 5)
		if not DST_MAC then
			log:info("ARP lookup failed, using default destination mac address")
			return
		end
	end
	log:info("Destination mac: %s", DST_MAC)
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
	_, _, _, rxStats = rxCtr:getStats()
	_, _, _, txStats = txCtr:getStats()
	if rxStats < txStats then
		log:warn("In: %s, Out: %s, dropped %s ( %.2f %%) packets", rxStats, txStats, (txStats - rxStats), (txStats - rxStats)/txStats*100)

	end

end

function loadSlave(queue, rxDev, size, flows, time)
	doArp()
	local mempool = memory.createMemPool(function(buf)
		fillUdpPacket(buf, size)
	end)
	local bufs = mempool:bufArray()
	local counter = 0
--	local txCtr = stats:newDevTxCounter(queue, "plain")
--	local rxCtr = stats:newDevRxCounter(rxDev, "plain")
	local baseIP = parseIPAddress(SRC_IP_BASE)
	-- runtime timer
        local runtime = nil
        if ( time > 0 ) then
                runtime = timer:new(time)
        end
	--queue:start()
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
		-- rxCtr:update()
--		txCtr:update()
	end
	if queue.stop then
                queue:stop()
        end

--	rxCtr:finalize()
--	txCtr:finalize()
end

function timerSlave(txQueue, rxQueue, size, flows, time)
	doArp()
	if size < 84 then
		log:warn("Packet size %d is smaller than minimum timestamp size 84. Timestamped packets will be larger than load packets.", size)
		size = 84
	end
	local timestamper = ts:newUdpTimestamper(txQueue, rxQueue)
	local hist = hist:new()
	mg.sleepMillis(1000) -- ensure that the load task is running
	local counter = 0
	local rateLimit = timer:new(0.001)
	local baseIP = parseIPAddress(SRC_IP_BASE)
	-- runtime timer
        local runtime = nil
        if ( time > 0 ) then
                runtime = timer:new(time)
        end

	while mg.running() and (not runtime or runtime:running()) do
		hist:update(timestamper:measureLatency(size, function(buf)
			fillUdpPacket(buf, size)
			local pkt = buf:getUdpPacket()
			pkt.ip4.src:set(baseIP + counter)
			counter = incAndWrap(counter, flows)
		end))
		rateLimit:wait()
		rateLimit:reset()
	end
	-- print the latency stats after all the other stuff
	mg.sleepMillis(300)
	hist:print()
	hist:save("histogram.csv")
end

