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
local tikz          = require "utils.tikz"

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

local FRAME_SIZES = {64, 128, 256, 512, 1024, 1280, 1518}


function configure(parser)
	parser:description("Generates UDP traffic and measure latencies. Edit the source to modify constants like IPs.")
	parser:argument("txDev", "Device to transmit from."):convert(tonumber)
	parser:argument("rxDev", "Device to receive from."):convert(tonumber)
	parser:option("-i --iterations", "How many partitions?"):default(15)
	parser:option("-r --rate", "Transmit rate in Mbit/s."):default(10000)
	parser:option("-f --flows", "Number of flows (randomized source IP)."):default(20):convert(tonumber)
	parser:option("-s --size", "Packet size."):default(60):convert(tonumber)
	parser:option("-n --threads", "Number of Threads to use"):default(1):convert(tonumber)
	parser:option("-t --time", "Time in seconds"):default(120):convert(tonumber)
	parser:option("-l --limiter", "Ratelimiter to use"):default("hardware")
end


function master(args)
    size = args.size
    local bar = barrier:new(args.threads + 1)
    -- Setup Devices
	txDev = device.config{port = args.txDev, rxQueues = 1 , txQueues = args.threads }
	rxDev = device.config{port = args.rxDev, rxQueues = 1 , txQueues = args.threads }
	-- Wait for links to come up.
	device.waitForLinks()
	local results = {}
    local FRAME_SIZES   = {64, 128, 256, 512, 1024, 1280, 1518}
    log:info("===========================")
    log:info("  Running Frameloss test   ")
    log:info("===========================")
    local maxSpeed = txDev:getLinkStatus().speed
    for _, framesize in ipairs(FRAME_SIZES) do
        local startRate = rateparser.parse_rate("0.1Mp/s", framesize)
        local endRate = rateparser.parse_rate(maxSpeed, framesize)
        local result = {}
        for i=0, args.iterations - 1, 1 do
            local testRate = startRate + i* ((maxSpeed - startRate)/(args.iterations - 1))
            --testRate = 7168
            log:info("framesize: %s, rate %s", framesize, testRate)
            local orate, tpkts, rpkts = test(args, testRate, framesize, bar)
            local elem = {}
            elem.framesize = framesize
            elem.orate     = wireRateMPPS(orate.median)
            elem.tpkts     = tpkts
            elem.rpkts     = rpkts
            table.insert(result, elem)
            log:info("%s",  resultToCSV(result, args))
            mg.sleepMillis(1000)
        end
        table.insert(results, result)
    end
    toTikz("frameloss", args, unpack(results))
end

function getCSVHeader()
    local str = "percent of link rate,frame size,duration,received packets,sent packets,frameloss in %"
    return str
end

function resultToCSV(result, args)
    local str = ""
    for k,v in ipairs(result) do
        str = str .. v.orate .. "," .. v.framesize .. "," .. args.time .. "," .. v.rpkts .. "," .. v.tpkts .. "," .. (v.tpkts - v.rpkts) / (v.tpkts) * 100
        if result[k+1] then
            str = str .. "\n"
        end
    end
    return str
end

function toTikz(filename, args, ...)
    local fl = tikz.new(filename .. "_percent" .. ".tikz", [[xlabel={link rate [\%]}, ylabel={frameloss [\%]}, grid=both, ymin=0, xmin=0, xmax=100,scaled ticks=false, width=9cm, height=4cm, cycle list name=exotic,legend style={at={(1.04,1)},anchor=north west}]])
    local th = tikz.new(filename .. "_throughput" .. ".tikz", [[xlabel={offered load [mpps]}, ylabel={throughput [mpps]}, grid=both, ymin=0, xmin=0, scaled ticks=false, width=9cm, height=4cm, cycle list name=exotic,legend style={at={(1.02,1)},anchor=north west}]])
    
    local numResults = select("#", ...)
    for i=1, numResults do
        local result = select(i, ...)
        
        fl:startPlot()
        th:startPlot()
        
        local frameSize
        for _, p in ipairs(result) do
            frameSize = p.framesize
            
            fl:addPoint(p.orate, (p.tpkts - p.rpkts) / p.tpkts * 100)
            
            local offeredLoad = p.tpkts / 10^6 / args.time
            local throughput = p.rpkts / 10^6 /  args.time
            th:addPoint(offeredLoad, throughput)
        end
        fl:addPoint(0, 0)
        fl:endPlot(frameSize .. " bytes")
        
        th:addPoint(0, 0)
        th:endPlot(frameSize .. " bytes")
        
    end
    fl:finalize()
    th:finalize()
end


function wireRateMPPS(rate)
	return rate/(8*(size + 4))
end

function test(args, rate, framesize, bar)
	-- Start Counter Thread first to not miss any packets.
	bar:reinit(args.threads + 1) 
	local counterTask = mg.startTask("ctrSlave", txDev, rxDev, args.time, bar)
	
	-- Create Rate-limiters for each thread!
	-- Since the hardware-rate-limiter fails for small packet rates, we will use a sofware-ratelimiter for these.
	for i = 1, args.threads do
		local txQueue
		if ( false )
		then
			txQueue = limiter:new(txDev:getTxQueue(i - 1), "cbr", 8000 * (args.size + 4) / (rate / args.threads))
			log:info("Using Software Rate-Limiter")
		else 
			txDev:setRate(rate)
			txQueue = txDev:getTxQueue(i - 1)
			log:info("Using HW Rate-Limiter")
		end

		mg.startTask("loadSlave", txQueue, rxDev, framesize - 4, args.flows, args.time, bar)
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

function ctrSlave(txDev, rxDev, time, bar)
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
	local _, rxmbit, _, rxStats = rxCtr:getStats()
	local _, txmbit, _, txStats = txCtr:getStats()
	local actualRX = tonumber(rxStats - initialRX)
	local actualTX = tonumber(txStats - initialTX)
	if rxStats < txStats then
		log:warn("In: %s, Out: %s, dropped %s ( %.2f %%) packets", actualRX, actualTX, (actualTX - actualRX), (actualTX - actualRX)/actualTX*100)

	end
	return txmbit, actualTX, actualRX

end

function loadSlave(queue, rxDev, size, flows, time, bar)
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
	--if (type(queue) == "table" ) then
        queue:start()
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
