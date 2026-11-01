--[[--
Pure Lua md5 (RFC 1321): main.lua uses it to hash books.

No bitwise operators, so the same file runs on Lua 5.1, LuaJIT (the
interpreter KOReader ships) and Lua 5.3+: `bit` is used when the module is
there, plain arithmetic otherwise. The test vectors are checked inside
test_main.lua against the official strings, so a mistake in the
implementation shows up immediately.
--]]

local has_bit, bitlib = pcall(require, "bit")

local band, bor, bxor, bnot, lshift, rshift

if has_bit and bitlib then
    -- LuaJIT: fast path, with the signed results brought back to 0..2^32-1
    local function unsigned(x)
        if x < 0 then
            return x + 4294967296
        end
        return x
    end
    band = function(a, b) return unsigned(bitlib.band(a, b)) end
    bor = function(a, b) return unsigned(bitlib.bor(a, b)) end
    bxor = function(a, b) return unsigned(bitlib.bxor(a, b)) end
    bnot = function(a) return unsigned(bitlib.bnot(a)) end
    -- `bit` masks the shift count to five bits, so lshift(x, 32) is x and
    -- not 0. The length field asks for a shift by 32 or more: stop here.
    lshift = function(a, n)
        if n >= 32 then
            return 0
        end
        return unsigned(bitlib.lshift(a, n))
    end
    rshift = function(a, n)
        if n >= 32 then
            return 0
        end
        return unsigned(bitlib.rshift(a, n))
    end
else
    local function u32(x)
        x = x % 4294967296
        if x < 0 then
            x = x + 4294967296
        end
        return x
    end

    local function bits(a, b, keep)
        local res, place = 0, 1
        for _ = 1, 32 do
            local abit, bbit = a % 2, b % 2
            if keep(abit, bbit) then
                res = res + place
            end
            a = (a - abit) / 2
            b = (b - bbit) / 2
            place = place * 2
        end
        return res
    end

    band = function(a, b)
        return bits(a, b, function(x, y) return x == 1 and y == 1 end)
    end
    bor = function(a, b)
        return bits(a, b, function(x, y) return x == 1 or y == 1 end)
    end
    bxor = function(a, b)
        return bits(a, b, function(x, y) return x ~= y end)
    end
    bnot = function(a) return 4294967295 - u32(a) end
    lshift = function(a, n)
        for _ = 1, n do
            a = u32(a * 2)
        end
        return a
    end
    rshift = function(a, n)
        if n >= 32 then
            return 0
        end
        return math.floor(a / 2 ^ n)
    end
end

local function rotl(x, n)
    return bor(lshift(x, n), rshift(x, 32 - n))
end

local function add32(...)
    local sum = 0
    for i = 1, select("#", ...) do
        sum = sum + select(i, ...)
    end
    return sum % 4294967296
end

local function hex32(x)
    local out = {}
    for i = 0, 3 do
        out[#out + 1] = string.format("%02x", rshift(x, i * 8) % 256)
    end
    return table.concat(out)
end

local T = {
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
    0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
    0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
    0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
    0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
    0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
    0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
    0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
    0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
}

local S = {
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

local function md5hex(str)
    local msg = {}
    for i = 1, #str do
        msg[i] = string.byte(str, i)
    end
    local bit_len = #msg * 8
    msg[#msg + 1] = 0x80
    while #msg % 64 ~= 56 do
        msg[#msg + 1] = 0
    end
    for i = 0, 7 do
        msg[#msg + 1] = rshift(bit_len, 8 * i) % 256
    end

    local A, B, C, D = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
    local M = {}
    for chunk = 1, #msg, 64 do
        for i = 0, 15 do
            local o = chunk + i * 4
            M[i] = msg[o] + msg[o + 1] * 256
                + msg[o + 2] * 65536 + msg[o + 3] * 16777216
        end
        local a, b, c, d = A, B, C, D
        for i = 0, 63 do
            local f, g
            if i < 16 then
                f = bor(band(b, c), band(bnot(b), d))
                g = i
            elseif i < 32 then
                f = bor(band(d, b), band(bnot(d), c))
                g = (5 * i + 1) % 16
            elseif i < 48 then
                f = bxor(bxor(b, c), d)
                g = (3 * i + 5) % 16
            else
                f = bxor(c, bor(b, bnot(d)))
                g = (7 * i) % 16
            end
            f = add32(f, a, T[i + 1], M[g])
            a, b, c, d = d, add32(b, rotl(f, S[i + 1])), b, c
        end
        A = add32(A, a)
        B = add32(B, b)
        C = add32(C, c)
        D = add32(D, d)
    end
    return hex32(A) .. hex32(B) .. hex32(C) .. hex32(D)
end

return { md5 = md5hex }
