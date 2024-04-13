package.path = package.path .. "rfc2544/?.lua;../rfc2544/?.lua;"

if master == nil then
    master = "dummy"
end

local dpdk          = require "dpdk"
local device        = require "device"
local arp           = require "proto.arp"

local throughput    = require "benchmarks.throughput"
local latency       = require "benchmarks.latency"
local frameloss     = require "benchmarks.frameloss"
local backtoback    = require "benchmarks.backtoback"
local utils         = require "utils.utils"

local testreport    = require "utils.testreport"

local conf          = require "config"

local FRAME_SIZES   = {64, 128, 256, 512, 1024, 1280, 1518}

local usageString = [[

    --txport <txport> 
    --rxport <rxport> 
    
    --rths <throughput rate threshold> 
    --mlr <max throuput loss rate>
    
    --bths <back-to-back frame threshold>
    
    --duration <single test duration>
    --iterations <amount of test iterations>    
    
    --din <DuT in interface name>
    --dout <DuT out iterface name>
    --dskip <skip DuT configuration>
    
    --asksshpass <true|false> [ask at beginning for SSH password]
    --sshpass <SSH password>
    --sshuser <SSH user>
    --sshport <SSH port>
    --asksnmpcomm <true|false> [ask at beginning for SNMP community string]
    --snmpcomm <SNMP community string>
    --host <mgmt host name of the DuT>
]]

local date = os.date("%F_%H-%M")

function log(file, msg, linebreak)
    print(msg)
    file:write(msg)
    if linebreak then
        file:write("\n")
    end
end

function configure(parser)
	parser:description("Generates UDP traffic and measure latencies. Edit the source to modify constants like IPs.")
	parser:argument("txPort", "Device to transmit from."):convert(tonumber)
	parser:argument("rxPort", "Device to receive from."):convert(tonumber)
	parser:option("--rateThreshold", "<throughput rate threshold>"):default(100):convert(tonumber)
	parser:option("--btbThreshold", "Back to Back Threshold"):default(100):convert(tonumber)
	parser:option("--duration", "single test duration"):default(60):convert(tonumber)
	parser:option("--maxLossRate", "Max Lossrate"):default(1):convert(tonumber)
	parser:option("--dskip", "Skip dut Configuration"):default(true)
	parser:option("--numIterations", "amount of test iterations"):default(1):convert(tonumber)
	parser:option("--sshpass", "SSH-password"):default("123"):convert(tostring)
	parser:option("--asksshpass", "Ask for pass if needed"):default(true)
	parser:option("--sshuser", "ssh username"):default("cff29"):convert(tostring)
	parser:option("--sshport", "SSH-port"):default(22):convert(tonumber)
	parser:option("--snmpComm", "snmp-community"):default("default"):convert(tostring)
	parser:option("--asksnmpcomm", "Ask for snmp-community if needed"):default(true)
	parser:option("--din", "DUT in interface name"):default("DIn"):convert(tostring)
	parser:option("--dout", "DUT out interface name"):default("DOut"):convert(tostring) 
	parser:option("--host", "Hostname"):default("Trafficgen"):convert(tostring) 

end

function master(args)

    local txPort, rxPort = args.txPort, args.rxPort
    
    local rateThreshold = args.rateThreshold
    local btbThreshold  = args.btbThreshold
    local duration = args.duration
    local maxLossRate = args.maxLossRate
    local dskip = args.dskip
    local numIterations = args.numIterations
   
    if args.asksshpass == "true" then
        io.write("password: ")
        conf.setSSHPass(io.read())
        
    else
        conf.setSSHPass(args.sshpass)
    end

    conf.setSSHUser(args.sshuser)
    conf.setSSHPort(args.sshport)
    
    if args.asksnmpcomm == "true" then
        io.write("snmpcom ")
        conf.setSNMPComm(io.read())
    else
        conf.setSNMPComm(args.snmpcomm)
    end 
    
    conf.setHost(args.host)
    
    local dut = {
        ifIn = args.din,
        ifOut = args.dout
    }
    
    local rxDev, txDev
    if txPort == rxPort then
        -- sending and receiving from the same port
        txDev = device.config({port = txPort, rxQueues = 3, txQueues = 5})
        rxDev = txDev
    else
        -- two different ports, different configuration
        txDev = device.config({port = txPort, rxQueues = 2, txQueues = 5})
        rxDev = device.config({port = rxPort, rxQueues = 3, txQueues = 3})
    end
    device.waitForLinks()
    
    -- launch background arp table task
    if txPort == rxPort then 
        dpdk.launchLua(arp.arpTask, {
            { 
                txQueue = txDev:getTxQueue(0),
                rxQueue = txDev:getRxQueue(1),
                ips = {"198.18.1.2", "198.19.1.2"}
            }
        })
    else
        dpdk.launchLua(arp.arpTask, {
            {
                txQueue = txDev:getTxQueue(0),
                rxQueue = txDev:getRxQueue(1),
                ips = {"198.18.1.2"}
            },
            {
                txQueue = rxDev:getTxQueue(0),
                rxQueue = rxDev:getRxQueue(1),
                ips = {"198.19.1.2", "198.18.1.1"}
            }
        })
    end
    
    -- create testresult folder if not exist
    -- there is no clean lua way without using 3rd party libs
    local folderName = "testresults_" .. date
    os.execute("mkdir -p " .. folderName)    
    
    local report = testreport.new(folderName .. "/rfc_2544_testreport.tex")
    local results = {}
    
    local thBench = throughput.benchmark()
    thBench:init({
        txQueues = {txDev:getTxQueue(1), txDev:getTxQueue(2), txDev:getTxQueue(3)},
        rxQueues = {rxDev:getRxQueue(0)}, 
        duration = duration, 
        rateThreshold = rateThreshold,
        maxLossRate = maxLossRate,
        skipConf = dskip,
        dut = dut,
        numIterations = numIterations,
    })
    local rates = {}
    local file = io.open(folderName .. "/throughput.csv", "w")
    log(file, thBench:getCSVHeader(), true)
    for _, frameSize in ipairs(FRAME_SIZES) do
        local result, avgRate = thBench:bench(frameSize)
        rates[frameSize] = avgRate
        
        -- save and report results
        table.insert(results, result)
        log(file, thBench:resultToCSV(result), true)
        report:addThroughput(result, duration, maxLossRate, rateThreshold)
    end
    thBench:toTikz(folderName .. "/plot_throughput", unpack(results))
    file:close()
    
    results = {}
    local latBench = latency.benchmark()
    latBench:init({
        txQueues = {txDev:getTxQueue(1), txDev:getTxQueue(2), txDev:getTxQueue(3), txDev:getTxQueue(4)},
        -- different receiving queue, for timestamping filter
        rxQueues = {rxDev:getRxQueue(2)}, 
        duration = duration,
        skipConf = dskip,
        dut = dut,
    })
    
    file = io.open(folderName .. "/latency.csv", "w")
    log(file, latBench:getCSVHeader(), true)
    for _, frameSize in ipairs(FRAME_SIZES) do
        local result = latBench:bench(frameSize, math.ceil(rates[frameSize] * (frameSize + 20) * 8))
        
        -- save and report results        
        table.insert(results, result)
        log(file, latBench:resultToCSV(result), true)
        report:addLatency(result, duration)
    end
    latBench:toTikz(folderName .. "/plot_latency", unpack(results))
    file:close()
    
    results = {}
    local flBench = frameloss.benchmark()
    flBench:init({
        txQueues = {txDev:getTxQueue(1), txDev:getTxQueue(2), txDev:getTxQueue(3)},
        rxQueues = {rxDev:getRxQueue(0)}, 
        duration = duration,
        granularity = 0.05,
        skipConf = dskip,
        dut = dut,
    })
    file = io.open(folderName .. "/frameloss.csv", "w")
    log(file, flBench:getCSVHeader(), true)
    for _, frameSize in ipairs(FRAME_SIZES) do
        local result = flBench:bench(frameSize)
        
        -- save and report results
        table.insert(results, result)
        log(file, flBench:resultToCSV(result), true)
        report:addFrameloss(result, duration)
    end
    flBench:toTikz(folderName .. "/plot_frameloss", unpack(results))
    file:close()
    
    results = {}
    local btbBench = backtoback.benchmark()
    btbBench:init({
        txQueues = {txDev:getTxQueue(1)},
        rxQueues = {rxDev:getRxQueue(0)},
        granularity = btbThreshold,
        skipConf = dskip,
        numIterations = numIterations,
        dut = dut,
    })
    file = io.open(folderName .. "/backtoback.csv", "w")
    log(file, btbBench:getCSVHeader(), true)
    for _, frameSize in ipairs(FRAME_SIZES) do
        local result = btbBench:bench(frameSize)
        
        -- save and report results
        table.insert(results, result)
        log(file, btbBench:resultToCSV(result), true)
        report:addBackToBack(result, btbBench.duration, btbThreshold, txDev:getLinkStatus().speed)
    end
    btbBench:toTikz(folderName .. "/plot_backtoback", unpack(results))
    file:close()

    report:finalize()
    
end
