-- WoW runs Lua 5.1: string.format("%s", nil) raises there, while Lua 5.4 prints "nil". Make the test run behave like WoW.
local format = string.format
local strict = function(fmt, ...)
  local args = { ... }
  local i = 0
  for _, spec in tostring(fmt):gmatch("%%([%-%d%.]*)(%a)") do
    i = i + 1
    if spec == "s" and args[i] == nil then error(("bad argument #%d to 'format' (string expected, got nil)"):format(i + 1), 2) end
  end
  return format(fmt, ...)
end
string.format = strict
