--[[--
md5 in puro Lua (RFC 1321): serve a main.lua per hashare i libri.

Usa gli operatori bitwise di Lua 5.3+ (la suite gira con `lua`).
I vettori di prova sono verificati dentro test_main.lua contro le stringhe
ufficiali, così un errore nell'implementazione viene subito fuori.
--]]

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

local function rotl(x, n)
    x = x & 0xffffffff
    return ((x << n) | (x >> (32 - n))) & 0xffffffff
end

local function hex32(x)
    local out = {}
    for i = 0, 3 do
        out[#out + 1] = string.format("%02x", (x >> (i * 8)) & 0xff)
    end
    return table.concat(out)
end

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
        msg[#msg + 1] = (bit_len >> (8 * i)) & 0xff
    end

    local A, B, C, D = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
    local M = {}
    for chunk = 1, #msg, 64 do
        for i = 0, 15 do
            local o = chunk + i * 4
            M[i] = msg[o] | (msg[o + 1] << 8) | (msg[o + 2] << 16) | (msg[o + 3] << 24)
        end
        local a, b, c, d = A, B, C, D
        for i = 0, 63 do
            local f, g
            if i < 16 then
                f = (b & c) | ((~b) & d)
                g = i
            elseif i < 32 then
                f = (d & b) | ((~d) & c)
                g = (5 * i + 1) % 16
            elseif i < 48 then
                f = b ~ c ~ d
                g = (3 * i + 5) % 16
            else
                f = c ~ (b | (~d))
                g = (7 * i) % 16
            end
            f = (f + a + T[i + 1] + M[g]) & 0xffffffff
            a = d
            d = c
            c = b
            b = (b + rotl(f, S[i + 1])) & 0xffffffff
        end
        A = (A + a) & 0xffffffff
        B = (B + b) & 0xffffffff
        C = (C + c) & 0xffffffff
        D = (D + d) & 0xffffffff
    end
    return hex32(A) .. hex32(B) .. hex32(C) .. hex32(D)
end

return { md5 = md5hex }
