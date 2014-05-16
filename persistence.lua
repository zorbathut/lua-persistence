--[[
Copyright (c) 2010 The Color Black
Copyright (c) 2011-2014 Trion Worlds, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
]]

local type = _G.type
local tostring = _G.tostring
local rawget = _G.rawget
local sformat = _G.string.format
local tinsert = _G.table.insert
local tremove = _G.table.remove
local tconcat = _G.table.concat
local tsort = _G.table.sort
local pairs = _G.pairs
local ipairs = _G.ipairs
local print = _G.print
local select = _G.select
local unpack = _G.unpack
local loadstring = _G.loadstring
local max = _G.math.max
local time = _G.os.time

--[[ PERFORMANCE NOTES

For the sake of speed, the Trion Worlds codebase moves some functionality into C++.

Below are provided Lua equivalents of those functions. If you want this library to be really fast, you should probably reimplement them in C++.

If you do, please re-submit your implementations so we can add it to this repository :) ]]

local function StringIdentifierSafe(input)
  return string.match("[a-zA-Z_][a-zA-Z0-9_]*", input)
end

local function Append()
  local storage = {}
  return function(typ, data)
    if typ == nil then
      -- output
      storage = {table.concat(storage)}
      return storage[1]
    elseif typ == 0 then
      -- nil
      tinsert(storage, "nil")
    elseif typ == 1 then
      -- number
      tinsert(storage, tostring(data))
    elseif typ == 2 then
      -- string, must be safetied
      tinsert(storage, string.format("%q", data))
    elseif typ == 3 then
      -- true
      tinsert(storage, "true")
    elseif typ == 4 then
      -- false
      tinsert(storage, "false")
    else
      -- string, must be literal
      tinsert(storage, typ)
    end
    
    for i=table.getn(storage)-1, 1, -1 do
      if string.len(storage[i]) > string.len(storage[i+1]) then
        break
      end
      storage[i] = storage[i] .. table.remove(storage)
    end
  end
end

--[[ END OF PERFORMANCE SECTION ]]

local function sorter(a, b)
  if type(a) ~= type(b) then
    return type(a) < type(b)
  end
  
  if type(a) == "number" or type(a) == "string" then
    return a < b
  elseif type(a) == "boolean" then
    -- true goes before false
    if a == b then
      return false
    else
      return a
    end
  else
    -- welp
    return tostring(a) < tostring(b)
  end
end

local luaKeywords = {}
for _, v in ipairs{"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"} do
  luaKeywords[v] = true
end

local function isSafeString(str)
  return type(str) == "string" and StringIdentifierSafe(str) and not luaKeywords[str]
end

local write
local function writerTable(f, item, level, refs, inline)
  if inline and inline[item] then
    return true
  end
  if inline then
    inline[item] = true
  end
  
  if refs[item] then
    -- Table with multiple references
    f("ref["..refs[item].."]")
  else
    -- Single use table
    f("{")
    
    -- We do our best to make things pretty
    local needcomma = false
    
    -- First, we put in consecutive values
    local len = 0
    if type(item) == "table" then
      len = #item
    end -- userdatas will be ignored, so we'll jsut go straight to pairs
    
    for i = 1, len do
      local v = rawget(item, i)
      if needcomma then
        f(",")
        if inline then
          f(" ")
        end
      end
      needcomma = true
      if not inline then
        f("\n")
        f(("\t"):rep(level + 1))
      end
      
      if write(f, v, level + 1, refs, inline) then return true end
    end
    
    local order = {}
    for k, v in pairs(item) do
      if type(k) ~= "number" or k < 1 or k > len then
        tinsert(order, k)
      end
    end
    tsort(order, sorter)
    
    for _, k in ipairs(order) do
      if needcomma then
        f(",")
        if inline then
          f(" ")
        end
      end
      needcomma = true
      if not inline then
        f("\n")
        f(("\t"):rep(level + 1))
      end
      
      if isSafeString(k) then
        f(k)
        f(" = ")
      else
        f("[")
        if write(f, k, level + 1, refs, inline) then return true end
        f("] = ")
      end
      
      local v = item[k]
      if write(f, v, level + 1, refs, inline) then return true end
    end

    if not inline then
      f("\n")
      f(("\t"):rep(level))
    end
    f("}")
  end
end

local writers = {
  ["nil"] = function (f, item)
    f(0)
  end,
  ["number"] = function (f, item)
    f(1, item)
  end,
  ["string"] = function (f, item)
    f(2, item)
  end,
  ["boolean"] = function (f, item)
    if item then
      f(3)
    else
      f(4)
    end
  end,
  ["table"] = writerTable,
  ["function"] = function (f, item)
    -- can, meet worms
    f("nil --[[" .. tostring(item) .. "]]");
  end,
  ["thread"] = function (f, item)
    f("nil --[[" .. tostring(item) .. "]]");
  end,
  ["userdata"] = writerTable, -- we pretend this is a table for the sake of serialization. we won't lose any useful data - it would have been nil otherwise - and we gain the ability to dump the Event.UI hierarchy.
}

local function write(f, item, level, refs, used)
  return writers[type(item)](f, item, level, refs, used)
end

local function refCount(objRefCount, item)
-- only count reference types (tables)
  if type(item) == "table" then
    local rv = false
    -- Mark as an overflow
    if objRefCount[item] then
      objRefCount[item] = objRefCount[item] + 1
      rv = true
    else
      objRefCount[item] = 1
      -- If first encounter, traverse
      for k, v in pairs(item) do
        if refCount(objRefCount, k) then rv = true end
        if refCount(objRefCount, v) then rv = true end
      end
    end
    return rv
  end
end

-- At some point we should maybe expose this to the outside world.
-- forceSplitMode - nil or 0, 1, 2
local function persist(input, actives, f_out, forceSplitMode)
  -- default
  forceSplitMode = forceSplitMode or 0
  
  -- hacky solution to deal with serialization problems: just step up the mode as we go and make sure it parses.
  -- this should probably be dealt with better but I'm honestly not sure how
  local append = Append()

  -- Count references
  local objRefCount = {} -- Stores reference that will be exported
  local refsNeeded = false
  local items = {}
  for k, v in pairs(input) do
    tinsert(items, k)
    if refCount(objRefCount, k) then refsNeeded = true end
    if refCount(objRefCount, v) then refsNeeded = true end
  end
  for k in pairs(actives) do
    if input[k] == nil then
      tinsert(items, k)
      if refCount(objRefCount, k) then refsNeeded = true end
    end
  end
  
  -- luajit has a limitation where more than 65k constants in one table causes parse errors.
  -- in that case, we pretend *everything* is a reference, so we can still save it properly.
  local totalobjs = 0
  local functionsplit = false
  for _ in pairs(objRefCount) do
    totalobjs = totalobjs + 1
  end
  if totalobjs > 65000 then
    forceSplitMode = max(forceSplitMode, 2)
  end

  if forceSplitMode >= 1 then
    refsNeeded = true
    for k in pairs(objRefCount) do
      objRefCount[k] = objRefCount[k] + 1 -- "now it's more than one"
    end
  end
  
  if forceSplitMode >= 2 then
    functionsplit = true
  end
  
  -- Export Objects with more than one ref and assign name
  local objRefNames = {}
  if refsNeeded then
    -- First, create empty tables for each
    local objRefIdx = 0
    for obj, count in pairs(objRefCount) do
      if count > 1 then
        objRefIdx = objRefIdx + 1
        objRefNames[obj] = objRefIdx
      end
    end
    append("local ref = {}\n")
    append(sformat("for k=1,%d do ref[k] = {} end\n", objRefIdx))

    -- Then fill them (this requires all empty multiRefObjects to exist)
    -- Unlike the early segment, we're putting limited effort into making this pretty
    -- if you're doing something that relies on this it's going to be ugly anyway.
    if functionsplit then
      append(";(function ()  -- function to split up constants in order to avoid luajit design limits\n")
    end
    local fct = 0
    for obj, idx in pairs(objRefNames) do
      for k, v in pairs(obj) do
        fct = fct + 2
        append("ref["..idx.."]")
        if isSafeString(k) then
          append(".")
          append(k)
        else
          append("[")
          write(append, k, 0, objRefNames)
          append("]")
        end
        append(" = ")
        write(append, v, 0, objRefNames)
        append("\n")
        if functionsplit and fct > 65500 then
          fct = 0
          append("end)()\n")
          append(";(function ()  -- function to split up constants in order to avoid luajit design limits\n")
        end
      end
    end
    if functionsplit then
      append("end)()\n")
    end
  end
  
  tsort(items, sorter)
  for _, k in ipairs(items) do
    if isSafeString(k) then
      append(k)
      append(" = ")
    else
      append("_G[")
      write(append, k, 0, objRefNames)
      append("] = ")
    end
    
    write(append, rawget(input, k), 0, objRefNames)
    
    append("\n")
  end
  
  local result = append(nil) -- done!
  append = nil
  
  if not loadstring(result) then
    if forceSplitMode >= 2 then
      error("Cannot persist properly, please report this")
    else
      persist(input, actives, f_out, forceSplitMode + 1)
    end
  else
    f_out(result)
  end
end

function serializeFull(elements, exists)
  local append = Append()
  
  persist(elements, exists or elements, append)
  
  return append(nil)
end

function serializeInline(element)
  local append = Append()
  
  if write(append, element, 0, {}, {}) then
    return nil
  else
    return append(nil)
  end
end

function _G.dump(...)
  local stringized = {}
  local elements = select("#", ...)
  for k = 1, elements do
    local element = select(k, ...)
    if type(element) == "table" then
      stringized[k] = serializeInline(element) or "(serialization failed)"
    else
      stringized[k] = element
    end
  end
  -- intentionally using _G.print here
  _G.print(unpack(stringized, 1, elements))
end
