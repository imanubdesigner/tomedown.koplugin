--[[--
Checks that the committed Codeberg copies of README.md and TUTORIAL.md
are exactly what tools/readme_variant.lua builds from the canonical
files: one README per hosting domain, never two documents that disagree
about where the releases live. The conversion must also be stable on its
own output, so a branch that copies the variant over README.md (it is
the file the forge renders) keeps this test green.
--]]
local HERE = arg[0]:match("^(.*)/") or "."
package.path = HERE .. "/?.lua;" .. package.path
local T = require("common")

local variant = dofile(T.plugin .. "/tools/readme_variant.lua")

-- index of the first line the two texts disagree on, or nil
local function firstDiff(a, b)
    local la, lb = {}, {}
    for line in a:gmatch("([^\n]*)\n") do
        la[#la + 1] = line
    end
    for line in b:gmatch("([^\n]*)\n") do
        lb[#lb + 1] = line
    end
    for i = 1, math.max(#la, #lb) do
        if la[i] ~= lb[i] then
            return i
        end
    end
    return nil
end

for _, doc in ipairs({ "README", "TUTORIAL" }) do
    local source_name = doc .. ".md"
    local copy_name = doc .. ".codeberg.md"
    local source = T.readFile(T.plugin .. "/" .. source_name)
    if T.check(source ~= nil, "source readable: " .. source_name) then
        local generated = variant.transform(source_name, source)
        T.check(variant.transform(source_name, generated) == generated,
            source_name .. " converts stably")
        local copy = T.readFile(T.plugin .. "/" .. copy_name)
        if T.check(copy ~= nil, "copy readable: " .. copy_name) then
            local at = firstDiff(copy, generated)
            T.check(copy == generated, at
                and (copy_name .. " stale at line " .. at
                    .. " (regenerate: lua tools/readme_variant.lua "
                    .. source_name .. " > " .. copy_name .. ")")
                or (copy_name .. " matches " .. source_name))
            T.check(not T.contains(copy, "github.com/imanubdesigner"),
                copy_name .. " does not link back to the GitHub repository")
        end
    end
end

-- an editor that lines the cells of a table up pads them with spaces:
-- the row rule must still match, and the generated row must not contain
-- a link back to the GitHub repository
local padded = "|  [Releases](https://github.com/imanubdesigner/tomedown.koplugin/releases)  "
    .. "|  zips and release notes  |\n"
local converted = variant.transform("README.md", padded)
T.check(T.contains(converted, "codeberg.org"), "a padded table row still converts")
T.check(not T.contains(converted, "github.com/imanubdesigner"),
    "a padded table row loses its GitHub link")

T.finish("test_readme")
