-- Consistency check of the generated Data/*.lua files. Plain Lua 5.4, offline, no cache needed.
--   lua tools/check-data.lua [dataDir] [--baseline <dir with the committed Data files>] [--list-all]
-- One line per problem ("ERROR Data/File.lua: ..." or "WARN ..."), counts at the end, exit code 1 when there is an error.
-- Problems listed in tools/check-data-known.lua are known upstream data gaps: they are counted, not reported (--list-all shows them).
-- The checks are in tools/datacheck.lua (also run by spec/datacheck_spec.lua).
local here = (arg[0]:match("^(.*)/[^/]*$") or ".")
package.path = here .. "/?.lua;" .. package.path
local datacheck = require("datacheck")

local dir, baseline, listAll = here .. "/../Data", nil, false
local i = 1
while arg[i] do
  if arg[i] == "--baseline" then baseline = arg[i + 1]; i = i + 1
  elseif arg[i] == "--list-all" then listAll = true
  else dir = arg[i] end
  i = i + 1
end

local known = {}
local ok, list = pcall(dofile, here .. "/check-data-known.lua")
if ok and type(list) == "table" then known = list end

local report = datacheck.run(dir, baseline, known)
for _, e in ipairs(listAll and report.all or report.errors) do print("ERROR " .. e) end
for _, w in ipairs(report.warnings) do print("WARN " .. w) end
local c = report.counts
print(("check-data: %d errors, %d warnings (%d known problems not reported); looked at %d files, %d npcs, %d recipes, %d beasts, %d points, %d map uses")
  :format(#report.errors, #report.warnings, c.known, c.files, c.npcs, c.recipes, c.beasts, c.points, c.maps))
os.exit(#report.errors > 0 and 1 or 0)
