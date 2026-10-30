--[[--
Builds the Codeberg-flavoured copies of README.md and TUTORIAL.md.

README.md is the canonical document: it lives on the GitHub home of the
project and links there. README.codeberg.md is generated from it by
rewriting the handful of lines that name a host - the release, test and
license badges and the Releases and Issues links - so that a reader on
Codeberg never follows a link back to a GitHub that may be unreachable.
tests/test_readme.lua fails when the committed copies drift from this
script's output.

    lua tools/readme_variant.lua README.md > README.codeberg.md
    lua tools/readme_variant.lua TUTORIAL.md > TUTORIAL.codeberg.md

A rule matches whole lines, never pieces of a sentence: editing a source
line then changes the generated copy (and the test says so) instead of
leaving a half-converted paragraph behind. Inside a Markdown table the
spaces an editor adds to line the cells up are ignored, and the row is
padded back to its column width so the table stays straight.
--]]

local M = {}

-- { from = "<exact line>", to = "<line or lines>" } replaces every
-- occurrence of that line (a "\n" in `to` writes several lines);
-- { from = "<exact line>", to = false } drops it.
M.rules = {
    ["README.md"] = {
        -- what Codeberg shows instead of the GitHub release badge: the
        -- project on its own forge, then the latest release (the Forgejo
        -- API answers the dynamic badge the same way the GitHub one did)
        {
            from = [[  <a href="https://github.com/imanubdesigner/tomedown.koplugin/releases/latest"><img src="https://img.shields.io/github/v/release/imanubdesigner/tomedown.koplugin?style=for-the-badge&color=171717&labelColor=171717&logo=github&logoColor=white" alt="Latest release"></a>]],
            to = table.concat({
                [[  <a href="https://codeberg.org/imanubdesigner/tomedown.koplugin"><img src="https://img.shields.io/badge/Codeberg-171717?style=for-the-badge&logo=codeberg&logoColor=white" alt="Codeberg"></a>]],
                [[  <a href="https://codeberg.org/imanubdesigner/tomedown.koplugin/releases/latest"><img src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fcodeberg.org%2Fapi%2Fv1%2Frepos%2Fimanubdesigner%2Ftomedown.koplugin%2Freleases%2Flatest&query=%24.tag_name&label=release&color=171717&labelColor=171717&logo=codeberg&logoColor=white&style=for-the-badge" alt="Latest release"></a>]],
            }, "\n"),
        },
        -- Codeberg has no Actions for this repository (no test badge
        -- would render): the sentence would promise CI that does not run
        {
            from = [[  <a href="https://github.com/imanubdesigner/tomedown.koplugin/actions/workflows/test.yml"><img src="https://img.shields.io/github/actions/workflow/status/imanubdesigner/tomedown.koplugin/test.yml?style=for-the-badge&labelColor=171717&logo=githubactions&logoColor=white&label=tests" alt="Test status"></a>]],
            to = false,
        },
        -- the Forgejo repository API carries no license field, so the
        -- dynamic badge would render nothing here: same licence, static
        -- text, the all-dark style the other two badges use
        {
            from = [[  <a href="LICENSE"><img src="https://img.shields.io/github/license/imanubdesigner/tomedown.koplugin?style=for-the-badge&color=171717&labelColor=171717" alt="License"></a>]],
            to = [[  <a href="LICENSE"><img src="https://img.shields.io/badge/AGPL--3.0-171717?style=for-the-badge&logo=gnu&logoColor=white" alt="License AGPL-3.0"></a>]],
        },
        {
            from = [[   [Releases](https://github.com/imanubdesigner/tomedown.koplugin/releases)]],
            to = [[   [Releases](https://codeberg.org/imanubdesigner/tomedown.koplugin/releases)]],
        },
        {
            from = [[| [Releases](https://github.com/imanubdesigner/tomedown.koplugin/releases) | zips and release notes |]],
            to = [[| [Releases](https://codeberg.org/imanubdesigner/tomedown.koplugin/releases) | zips and release notes |]],
        },
        -- the mirror sends bug reports to its own tracker
        {
            from = [[Something wrong or missing? [Open an issue](https://github.com/imanubdesigner/tomedown.koplugin/issues).]],
            to = [[Something wrong or missing? [Open an issue](https://codeberg.org/imanubdesigner/tomedown.koplugin/issues).]],
        },
        -- the discussions live on GitHub only, and a Codeberg reader is
        -- pointed there only for the repository itself: the mirror sends
        -- questions to its own issues
        {
            from = [[  Questions, ideas, feedback: <a href="https://github.com/imanubdesigner/tomedown.koplugin/discussions">GitHub Discussions</a>]],
            to = [[  Questions, ideas, feedback: <a href="https://codeberg.org/imanubdesigner/tomedown.koplugin/issues">Codeberg Issues</a>]],
        },
    },
    ["TUTORIAL.md"] = {
        {
            from = [[- [Releases](https://github.com/imanubdesigner/tomedown.koplugin/releases) —]],
            to = [[- [Releases](https://codeberg.org/imanubdesigner/tomedown.koplugin/releases) —]],
        },
        {
            from = [[- [Issues](https://github.com/imanubdesigner/tomedown.koplugin/issues) —]],
            to = [[- [Issues](https://codeberg.org/imanubdesigner/tomedown.koplugin/issues) —]],
        },
    },
}

local function trim(s)
    return (s:match("^%s*(.-)%s*$"))
end

--- The trimmed cells of a Markdown table row, or nil for any other line.
local function cells_of(line)
    if line:sub(1, 1) ~= "|" or line:sub(-1) ~= "|" then
        return nil
    end
    local cells = {}
    for cell in (line:sub(2, -2) .. "|"):gmatch("([^|]*)|") do
        cells[#cells + 1] = trim(cell)
    end
    if #cells < 2 then
        return nil
    end
    return cells
end

local function same_cells(a, b)
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

--- The rows of one table, padded so every cell in a column starts at the
-- same place. An editor that lines the cells up leaves the table in the
-- canonical file with spaces that a longer URL would break: the block is
-- rebuilt instead of patched row by row.
local function align_block(block)
    for _, line in ipairs(block) do
        if line:find("\\|", 1, true) then
            return block
        end
    end
    local rows, width, cols = {}, {}, 0
    for i, line in ipairs(block) do
        rows[i] = {}
        for cell in (line:sub(2, -2) .. "|"):gmatch("([^|]*)|") do
            rows[i][#rows[i] + 1] = trim(cell)
        end
        cols = math.max(cols, #rows[i])
    end
    local function is_rule(row)
        for _, cell in ipairs(row) do
            if not cell:match("^:?-+:?$") then
                return false
            end
        end
        return true
    end
    for _, row in ipairs(rows) do
        if not is_rule(row) then
            for i, cell in ipairs(row) do
                width[i] = math.max(width[i] or 0, #cell)
            end
        end
    end
    local out = {}
    for i, row in ipairs(rows) do
        local rule, cells = is_rule(row), {}
        for j = 1, cols do
            local cell = row[j] or ""
            local span = width[j] or #cell
            if rule then
                cell = string.rep("-", span)
            end
            cells[j] = " " .. cell .. string.rep(" ", span - #cell) .. " "
        end
        out[i] = "|" .. table.concat(cells, "|") .. "|"
    end
    return out
end

--- `lines` with every table that holds a replaced row re-aligned; the
-- other tables are left byte for byte as they were.
local function align_tables(lines, replaced)
    local out, i, n = {}, 1, #lines
    while i <= n do
        if cells_of(lines[i]) then
            local j = i
            while j < n and cells_of(lines[j + 1]) do
                j = j + 1
            end
            local touched = false
            for k = i, j do
                touched = touched or replaced[k] == true
            end
            local block = {}
            for k = i, j do
                block[#block + 1] = lines[k]
            end
            if touched then
                block = align_block(block)
            end
            for k = 1, #block do
                out[#out + 1] = block[k]
            end
            i = j + 1
        else
            out[#out + 1] = lines[i]
            i = i + 1
        end
    end
    return out
end

--- The given document with the rules for `name` applied. Returns the
-- new text and, second, how many lines each rule replaced or dropped -
-- 0 meaning that rule no longer matches anything in its source.
function M.transform(name, text)
    local rules = M.rules[name]
    if not rules then
        error("readme_variant: no rules for " .. tostring(name))
    end
    local counts = {}
    for i = 1, #rules do
        counts[i] = 0
    end
    local last_line_closed = text:match("\n$") ~= nil
    local lines = {}
    for line in text:gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    if not last_line_closed and text ~= "" then
        lines[#lines + 1] = text:match("([^\n]*)$")
    end
    local out, replaced = {}, {}
    for _, line in ipairs(lines) do
        local converted = false
        local cells = cells_of(line)
        for i, rule in ipairs(rules) do
            local matches = line == rule.from
            if not matches and cells then
                local target = cells_of(rule.from)
                matches = target ~= nil and same_cells(target, cells)
            end
            if matches then
                counts[i] = counts[i] + 1
                if rule.to ~= false then
                    for newline in (rule.to .. "\n"):gmatch("([^\n]*)\n") do
                        out[#out + 1] = newline
                        replaced[#out] = true
                    end
                end
                converted = true
                break
            end
        end
        if not converted then
            out[#out + 1] = line
        end
    end
    out = align_tables(out, replaced)
    local converted_text = table.concat(out, "\n")
    if last_line_closed and converted_text ~= "" then
        converted_text = converted_text .. "\n"
    end
    return converted_text, counts
end

-- run directly: lua tools/readme_variant.lua README.md > README.codeberg.md
local script = (arg and arg[0]) or ""
if script:match("readme_variant%.lua$") then
    local path = arg[1]
    local name = path and path:match("([^/\\]+)$")
    local f = path and io.open(path, "rb")
    if not name or not f then
        io.stderr:write(
            "usage: lua tools/readme_variant.lua README.md > README.codeberg.md\n")
        os.exit(1)
    end
    local source = f:read("*a")
    f:close()
    io.write((M.transform(name, source)))
end

return M
