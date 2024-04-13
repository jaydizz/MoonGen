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
	parser:option("-r --rate", "Start Rate for Search"):default("10kp/s")
	parser:option("-e --endrate", "End Rate for Search"):default("3Mp/s")
	parser:option("-d --droprate", "Acceptable Droprate in percent"):default("1")
	parser:option("-f --flows", "Number of flows (randomized source IP)."):default(4):convert(tonumber)
	parser:option("-s --size", "Packet size."):default(60):convert(tonumber)
	parser:option("-n --threads", "Number of Threads to use"):default(1):convert(tonumber)
	parser:option("-t --time", "Time in seconds"):default(10):convert(tonumber)
end

local size

function master(args)
	local low   = rateparser.parse_rate( args.rate, args.size    + 4  )
	local high  = rateparser.parse_rate( args.endrate, args.size + 4  )
	size = args.size
	local testRate
	-- Setup Devices
	txDev = device.config{port = args.txDev, rxQueues = 1 , txQueues = args.threads }
	rxDev = device.config{port = args.rxDev, rxQueues = 1 , txQueues = args.threads }
	-- Wait for links to come up.
	device.waitForLinks()
	
	while not (high == low) do
		log:info("=======================================")
		log:info("Low: %s Mpps ( %s ), High: %s Mpps (%s)", wireRateMPPS(low), low, wireRateMPPS(high), high)
		testRate = math.floor(low + (high - low)/2)
		log:info("Testing rate %s Mpps (%s)", wireRateMPPS(testRate), testRate)
		local actualRate, dropped = test(args, testRate)
		log:info("Actual rate %s Mpps (%s)", wireRateMPPS(actualRate.median), actualRate.median)
		        local rxStats = rxDev:getStats()
		        local txStats = txDev:getStats()
        	log:info("ipacktes: " .. tostring(rxStats.ipackets))
	log:info("opacktes: " .. tostring(rxStats.opackets))
	log:info("ibytes: " .. tostring(rxStats.ibytes))
	log:info("obytes: " .. tostring(rxStats.obytes))
	log:info("imissed: " .. tostring(rxStats.imissed))
	log:info("ierrors: " .. tostring(rxStats.ierrors))
	log:info("oerrors: " .. tostring(rxStats.oerrors))
	log:info("rx_nombuf: " .. tostring(rxStats.rx_nombuf))
			log:info("opacktes: " .. tostring(txStats.opackets))

		
		if dropped then
			log:warn("We dropped Packets! Taking Lower interval")
			high = testRate
		else
			log:warn("We did not drop Packets! Taking Higher interval")
			low = testRate + 1
		end
		if ( low > high ) then
			log:info("No significant dropps occured within given Interval!")
			break
		end
	end
	
	log:info("Non Dropping Rate: %s Mpp/s, %s MBit/s", wireRateMPPS(testRate/ (8 * args.size + 4)), testRate)
end

-- Include 4 byte FCS in calculations
function wireRateMPPS(rate)
	return rate/(8*(size + 4))
end


function test(args, rate)
	-- Start Counter Thread first to not miss any packets.
	local percent = args.droprate/100
	local counterTask = mg.startTask("ctrSlave", txDev, rxDev, args.time, percent)
	
	-- Create Rate-limiters for each thread!
	-- Since the hardware-rate-limiter fails for small packet rates, we will use a sofware-ratelimiter for these. 
	for i = 1, args.threads do
		local txQueue
		if ( rate < 100) 
		then
			txQueue = limiter:new(txDev:getTxQueue(i - 1), "cbr", 8000 * (args.size + 4) / (rate / args.threads))
			log:info("Using Software Rate-Limiter")
		else 
			txDev:setRate(rate)
			txQueue = txDev:getTxQueue(i - 1)
			log:info("Using HW Rate-Limiter")
		end

		mg.startTask("loadSlave", txQueue, rxDev, args.size, args.flows, args.time)
	end
	mg.waitForTasks()
	return counterTask:wait()
	

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

function ctrSlave(txDev, rxDev, time, percent)
	local rxCtr = stats:newDevRxCounter(rxDev, "plain")
	local txCtr = stats:newDevTxCounter(txDev, "plain")
	
	--local _, _, _, rxStats = rxCtr:getStats()
	--local _, _, _, txStats = txCtr:getStats()
	--log:warn("In: %s, Out: %s, dropped %s ( %.2f %%) packets", rxStats, txStats, (txStats - rxStats), (txStats - rxStats)/txStats*100)

	-- runtime timer
        local runtime = nil
        if ( time > 0 ) then
                runtime = timer:new(time + 5)
        end
	while mg.running() and (not runtime or runtime:running()) do
		txCtr:update()
		rxCtr:update()
	end

	mg.sleepMillis(1000)
		txCtr:update()
		rxCtr:update()
	-- Wait for any packets in transit. 
	txCtr:finalize(500)
	rxCtr:finalize(500)
	-- Get latest stats
	local _, _, _, rxStats = rxCtr:getStats()
	local _, txmbit, _, txStats = txCtr:getStats()
	if rxStats < txStats then
		log:warn("In: %s, Out: %s, dropped %s ( %.2f %%) packets", rxStats, txStats, (txStats - rxStats), (txStats - rxStats)/txStats*100)

	end
	return txmbit,  ( ((txStats - rxStats)/txStats) > percent)

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
	mg.sleepMillis(250) -- ensure counter task is up
	queue:start()
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
	mg.sleepMillis(250)
	if queue.stop then
                queue:stop()
        end
	mg.sleepMillis(250)

end

