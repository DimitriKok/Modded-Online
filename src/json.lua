--- Minimal JSON encoder/decoder for the Modded Online wire protocol.
--- Supports objects, arrays, strings, numbers, booleans and null. Arrays are
--- detected as tables with contiguous integer keys starting at 1.

local module = {}

local ESCAPES = {
    ["\""] = "\\\"", ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

--- The escape scan, hoisted out of the gsub so the common case skips it. Every key
--- in the wire protocol is one or two plain letters and an input packet goes out
--- every frame (plus a resend every 40 ms), so this ran a closure-driven gsub over
--- "s", "f", "i" hundreds of times a second to change nothing. Byte-identical: the
--- pattern is the SAME character class, so when it does not match, gsub would have
--- returned the string unchanged.
--- @param s string
--- @return string
local function encodeString(s)
    if s:find("[%z\1-\31\\\"]") == nil then
        return "\"" .. s .. "\""
    end
    return "\"" .. s:gsub("[%z\1-\31\\\"]", function(c)
        return ESCAPES[c] or string.format("\\u%04x", c:byte())
    end) .. "\""
end

--- @param t table
--- @return boolean
local function isArray(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n == #t
end

--- Encode a Lua value as a JSON string.
--- @param value any
--- @return string
function module.encode(value)
    local kind = type(value)
    if value == nil then
        return "null"
    elseif kind == "boolean" then
        return value and "true" or "false"
    elseif kind == "number" then
        if math.type(value) == "integer" then
            return string.format("%d", value)
        end
        -- integral floats (e.g. timestamps) print exactly, without %d's
        -- float-to-integer conversion which can fail on some runtimes
        if value % 1 == 0 and value == value and math.abs(value) < 2 ^ 53 then
            return string.format("%.0f", value)
        end
        return string.format("%.10g", value)
    elseif kind == "string" then
        return encodeString(value)
    elseif kind == "table" then
        local parts = {}
        if isArray(value) then
            for _, v in ipairs(value) do
                parts[#parts + 1] = module.encode(v)
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        for k, v in pairs(value) do
            parts[#parts + 1] = encodeString(tostring(k)) .. ":" .. module.encode(v)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

--- @class MoJsonParser
--- @field s string
--- @field pos integer

local function parserError(parser, what)
    error(string.format("json: %s at position %d", what, parser.pos), 0)
end

local function skipWhitespace(parser)
    local _, last = parser.s:find("^[ \t\r\n]*", parser.pos)
    parser.pos = last + 1
end

local parseValue

local UNESCAPES = {
    ["\""] = "\"", ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f",
    n = "\n", r = "\r", t = "\t",
}

local function parseString(parser)
    local out = {}
    local pos = parser.pos + 1 -- past opening quote
    while true do
        local c = parser.s:sub(pos, pos)
        if c == "" then
            parserError(parser, "unterminated string")
        elseif c == "\"" then
            parser.pos = pos + 1
            return table.concat(out)
        elseif c == "\\" then
            local esc = parser.s:sub(pos + 1, pos + 1)
            if esc == "u" then
                local hex = parser.s:sub(pos + 2, pos + 5)
                local code = tonumber(hex, 16)
                if code == nil then
                    parserError(parser, "bad unicode escape")
                end
                -- non-ASCII code points become '?' — the protocol is ASCII
                out[#out + 1] = code < 128 and string.char(code) or "?"
                pos = pos + 6
            else
                out[#out + 1] = UNESCAPES[esc] or esc
                pos = pos + 2
            end
        else
            out[#out + 1] = c
            pos = pos + 1
        end
    end
end

local function parseNumber(parser)
    local numStr = parser.s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", parser.pos)
    local num = tonumber(numStr)
    if num == nil then
        parserError(parser, "bad number")
    end
    parser.pos = parser.pos + #numStr
    if num % 1 == 0 and math.abs(num) < 2 ^ 53 then
        num = math.floor(num) -- integral values become Lua integers (bit-op safe)
    end
    return num
end

--- @param parser MoJsonParser
--- @return any
parseValue = function(parser)
    skipWhitespace(parser)
    local c = parser.s:sub(parser.pos, parser.pos)
    if c == "{" then
        local obj = {}
        parser.pos = parser.pos + 1
        skipWhitespace(parser)
        if parser.s:sub(parser.pos, parser.pos) == "}" then
            parser.pos = parser.pos + 1
            return obj
        end
        while true do
            skipWhitespace(parser)
            if parser.s:sub(parser.pos, parser.pos) ~= "\"" then
                parserError(parser, "expected object key")
            end
            local key = parseString(parser)
            skipWhitespace(parser)
            if parser.s:sub(parser.pos, parser.pos) ~= ":" then
                parserError(parser, "expected ':'")
            end
            parser.pos = parser.pos + 1
            obj[key] = parseValue(parser)
            skipWhitespace(parser)
            local sep = parser.s:sub(parser.pos, parser.pos)
            parser.pos = parser.pos + 1
            if sep == "}" then
                return obj
            elseif sep ~= "," then
                parserError(parser, "expected ',' or '}'")
            end
        end
    elseif c == "[" then
        local arr = {}
        parser.pos = parser.pos + 1
        skipWhitespace(parser)
        if parser.s:sub(parser.pos, parser.pos) == "]" then
            parser.pos = parser.pos + 1
            return arr
        end
        while true do
            arr[#arr + 1] = parseValue(parser)
            skipWhitespace(parser)
            local sep = parser.s:sub(parser.pos, parser.pos)
            parser.pos = parser.pos + 1
            if sep == "]" then
                return arr
            elseif sep ~= "," then
                parserError(parser, "expected ',' or ']'")
            end
        end
    elseif c == "\"" then
        return parseString(parser)
    elseif c:match("[%-%d]") then
        return parseNumber(parser)
    elseif c == "t" and parser.s:sub(parser.pos, parser.pos + 3) == "true" then
        parser.pos = parser.pos + 4
        return true
    elseif c == "f" and parser.s:sub(parser.pos, parser.pos + 4) == "false" then
        parser.pos = parser.pos + 5
        return false
    elseif c == "n" and parser.s:sub(parser.pos, parser.pos + 3) == "null" then
        parser.pos = parser.pos + 4
        return nil
    end
    parserError(parser, "unexpected character '" .. c .. "'")
end

--- Decode a JSON string. Returns nil plus an error message on malformed input.
--- @param s string
--- @return any, string?
function module.decode(s)
    if type(s) ~= "string" or s == "" then
        return nil, "json: empty input"
    end
    local parser = { s = s, pos = 1 }
    local ok, result = pcall(parseValue, parser)
    if not ok then
        return nil, tostring(result)
    end
    return result, nil
end

NetJson = module
return module
