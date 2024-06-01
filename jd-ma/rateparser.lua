local units = {}

units.time = {
        [""] = 1,
        ms = 1 / 1000,
        s  = 1,
        m  = 60,
        h  = 3600,
}
units.timeError  = "Invalid time unit. Can be one of 'ms', 's', 'm', 'h'."

units.size = {
        [""] = 1,
        k = 10 ^ 3, ki = 2 ^ 10,
        m = 10 ^ 6, mi = 2 ^ 20,
        g = 10 ^ 9, gi = 2 ^ 30,
}
units.sizeError = "Invalid size unit. Can be <k|m|g>[i]<bit|b|p>"

units.bool = {
        ["0"] = false, ["1"] = true,
        ["false"] = false, ["true"] = true,
        ["no"] = false, ["yes"] = true,
}
units.boolError = "Invalid boolean. Can be one of (0|false|no) or (1|true|yes) respectively."

function units.parseBool(bool, default, error)
        local t = type(bool)

        if t == "string" then
                bool = units.bool[bool]
                if not error:assert(type(bool) == "boolean", units.boolError) then
                        return default
                end
        elseif t == "nil" then
                return default
        elseif t ~= "boolean" then
                error("Invalid argument. String or boolean expected, got %s.", t)
        end

        return bool
end



function units.parse_rate(rstring, psize)
        local num, unit, time = string.match(rstring, "^(%d+%.?%d*)(%a*)/?(%a*)$")
        if not num then
                return nil, "Invalid format. Should be '<number>[unit][/<time>]'."
        end

        num, unit, time = tonumber(num), string.lower(unit), units.time[time]
        if not time then
                return nil, units.timeError
        end

        if unit == "" then
                unit = units.size.m --default is mbit/s
        elseif string.find(unit, "bit$") then
                unit = units.size[string.sub(unit, 1, -4)]
        elseif string.find(unit, "b$") then
                unit = units.size[string.sub(unit, 1, -2)] * 8
        elseif string.find(unit, "p$") then
                unit = units.size[string.sub(unit, 1, -2)] * psize * 8
        else
                return nil, units.sizeError
        end

        unit = unit / 10 ^ 6 -- cbr is in mbit/s
        return num * unit / time
end

function units.getDelay(cbr, framesize, threads)
        --local cbr = self.results.rate
        if cbr then
                cbr = cbr / threads
                local psize = framesize -- True Framesize!
                -- cbr      => mbit/s        => bit/1000ns
                -- psize    => b/p           => 8bit/p
                return 8000 * psize / cbr -- => ns/p
        end
end

function units.swToHwRate(rate, framesize)
        return rate * ((framesize - 4)*8 - 20)/(framsize * 8)



return units