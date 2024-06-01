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
local barrier       = require "barrier"

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
	parser:option("-e --endrate", "End Rate for Search"):default("0")
	parser:option("-d --droprate", "Acceptable Droprate in percent"):default("1")
	parser:option("-f --flows", "Number of flows (randomized source IP)."):default(4):convert(tonumber)
	parser:option("-s --size", "Packet size."):default(60):convert(tonumber)
	parser:option("-n --threads", "Number of Threads to use"):default(1):convert(tonumber)
	parser:option("-t --time", "Time in seconds"):default(10):convert(tonumber)
	parser:option("-n --filename", "filename"):default("")
end


function master(args)
	local bar = barrier:new(2)
	-- Setup Devices
	txDev = device.config{port = args.txDev, rxQueues = 1 , txQueues = args.threads }
	rxDev = device.config{port = args.rxDev, rxQueues = 1 , txQueues = args.threads }
	-- Wait for links to come up.
	device.waitForLinks()
	local results = {}
	--local FRAME_SIZES   = {1518}
	local FRAME_SIZES   = {64, 128, 256, 512, 1024, 1280, 1518}
    local maxSpeed = txDev:getLinkStatus().speed

	for _, framesize in ipairs(FRAME_SIZES) do
		log:info("Testing for Framesize %s", framesize)
		local low   = math.ceil(rateparser.parse_rate( args.rate, framesize ))
		local high  = math.floor(rateparser.parse_rate( args.endrate, framesize  ))
		local maxRate = math.floor(rateparser.parse_rate(maxSpeed, framesize) * ( (framesize)/(framesize+20) ))
		if high > maxRate then
			high = maxRate
		end
		local testRate
		local result = {}

		while not (high == low) do
			log:info("=======================================")
			log:info("Low: %s Mpps ( %s ), High: %s Mpps (%s)", wireRateMPPS(low, framesize), low, wireRateMPPS(high, framesize), high)
			testRate = math.floor(low + (high - low)/2)
			log:info("Testing rate %s Mpps (%s)", wireRateMPPS(testRate, framesize), testRate)
			local actualRate, dropped = test(args, testRate, framesize, bar)
			log:info("Actual rate %s Mpps (%s)", wireRateMPPS(actualRate.median, framesize), actualRate.median)
			if dropped then
				log:warn("We dropped Packets! Taking Lower interval")
				high = testRate
			else
				log:warn("We did not drop Packets! Taking Higher interval")
				low = testRate + 1
			end
			if ( low >= high ) then
				log:info("No significant dropps occured within given Interval!")
				break
			end
		end
	result.framesize = framesize
	result.ndr       = wireRateMPPS(testRate, framesize)
	result.percent   = testRate/(rateparser.parse_rate(maxSpeed, framesize) * ( (framesize)/(framesize+20) )) * 100
	result.droprate  = args.droprate
	table.insert(results, result)
	log:info("Non Dropping Rate: %s Mpp/s, %s MBit/s", wireRateMPPS(testRate, framesize), testRate)
	resultToCSV(args.filename, results, args)
	end 
end

function getCSVHeader()
    local str = "name, framesize, ndr, percent of linkrate, percent acceptable drops\n"
    return str
end

function resultToCSV(filename, result, args)
    local file = io.open("ndr_" .. filename, 'w')
    local str = ""
    for k,v in ipairs(result) do
        str = str .. filename.. v.framesize .. "," .. v.ndr .. "," .. v.percent .. "," .. v.droprate
        if result[k+1] then
            str = str .. "\n"
        end
    end
    file:write(getCSVHeader())
    file:write(str)
    return str
end

-- Include 4 byte FCS in calculations
function wireRateMPPS(rate, size)
	return rate/(8*(size))
end


function test(args, rate, framesize, bar)
	-- Start Counter Thread first to not miss any packets.
	local percent = args.droprate/100
	log:info("Testing: %s", rate)
	bar:reinit(args.threads + 1) 
	local counterTask = mg.startTask("ctrSlave", txDev, rxDev, args.time, percent, bar)
	
	-- Create Rate-limiters for each thread!
	-- Since the hardware-rate-limiter fails for small packet rates, we will use a sofware-ratelimiter for these.
	for i = 1, args.threads do
		local txQueue
		local devQueue = txDev:getTxQueue(i - 1)
		devQueue:start()
		local mode
		if ( rate < 1000) 
		then
			--txQueue = limiter:new(txDev:getTxQueue(i - 1), "cbr", 8000 * (args.size + 4) /(rate / args.threads))
			txQueue = limiter:new(devQueue, "cbr", rateparser.getDelay(rate, framesize, args.threads))
			mode = "sw"
			log:info("Using Software Rate-Limiter")
		else 
			-- Tweak rate
			rate = rateparser.swToHwRate(rate, framesize)
			txDev:setRate(rate)
			txQueue = devQueue
			mode = "hw"
			log:info("Using HW Rate-Limiter")
		end

		mg.startTask("loadSlave", txQueue, rxDev, framesize - 4 , args.flows, args.time, bar, mode)
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

function ctrSlave(txDev, rxDev, time, percent, bar)
	local initialRXStats = rxDev:getStats()
	local initialRX       = initialRXStats.imissed + initialRXStats.ipackets
	local initialTXStats = txDev:getStats()
	local initialTX		 = initialTXStats.opackets
	
	local rxCtr = stats:newDevRxCounter(rxDev, "plain")
	local txCtr = stats:newDevTxCounter(txDev, "plain")

	-- runtime timer
    local runtime = nil
    if ( time > 0 ) then
        runtime = timer:new(time)
    end
	txCtr:update()
	rxCtr:update()
	bar:wait()
	mg.sleepMillis(1000) -- wait for DuT to settle
	initialRXStats = rxDev:getStats()
	initialRX       = initialRXStats.imissed + initialRXStats.ipackets
	initialTXStats = txDev:getStats()
	initialTX		 = initialTXStats.opackets
	while mg.running() and (not runtime or runtime:running()) do
		txCtr:update()
		rxCtr:update()
		local _, _, _, rxStats = rxCtr:getStats()
		local _, _, _, txStats = txCtr:getStats()
	end
	-- Wait for any packets in transit. 
	txCtr:finalize(500)
	rxCtr:finalize(500)
	-- Get latest stats
	local _, txmbit, _, _ = txCtr:getStats()
	local RXStats = rxDev:getStats()
    local rxStats = RXStats.imissed + RXStats.ipackets
    local TXStats = txDev:getStats()
    local txStats = TXStats.opackets
	local actualRX = tonumber(rxStats - initialRX)
	local actualTX = tonumber(txStats - initialTX)
	if rxStats < txStats then
		log:warn("In: %s, Out: %s, dropped %s ( %.2f %%) packets", actualRX, actualTX, (actualTX - actualRX), (actualTX - actualRX)/actualTX*100)

	end
	return txmbit,  ( ((actualTX - actualRX)/actualTX) > percent)

end

function loadSlave(queue, rxDev, size, flows, time, bar, mode)
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
	--if(mode == "hw") then
	--	queue:start()
	--else 
	--	queue.queue:start()
	--end
	bar:wait() -- wait for counterTask
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

