-- core.t
-- defines truss library functions, sets up require system

-- add our compatibility C standard library headers so systems without
-- dev tools can still use truss (e.g., windows without VS installed)
terralib.includepath = "include;include/compat"

local use_ryzen_hack = false
if use_ryzen_hack then
  print("Using Ryzen hack. Unclear on performance implications.")
  -- AMD Ryzen incorrectly reports its CPU as "generic" somehow, so manually set
  -- the default compile target
  local triple = "x86_64-pc-win32"
  terralib.nativetarget = terralib.newtarget{Triple = triple}

  -- this is completely undocumented, but needs to be derived from the newly made
  -- native target or else linking structures will break things for some reason
  terralib.jitcompilationunit = terralib.newcompilationunit(terralib.nativetarget, true)
end

-- Link in truss api
local ctruss = terralib.includec("truss_api.h")

-- strip truss_ from ctruss function names, put into truss table
-- (note, this is essentially the same function as in core/module.t,
-- but we haven't set up `require` yet)
truss = {}
truss.C_raw = ctruss
truss.C = {}
for k,v in pairs(ctruss) do
  if k:sub(1,6):lower() == "truss_" then
    local shortenedName = k:sub(7,-1)
    truss.C[shortenedName] = v
  end
end
truss.C.Message = truss.C.message -- style is Capitalized class/struct names

truss.C.test()
truss.C.log(truss.C.LOG_INFO, "Bootstrapping [" .. TRUSS_INTERPRETER_ID .. "]")
local TRUSS_ID = TRUSS_INTERPRETER_ID
truss.TRUSS_ID = TRUSS_ID
truss.interpreter_id = TRUSS_ID

local function stringify_args(...)
  local nargs = select('#', ...)
  local frags = {}
  for i = 1, nargs do
    frags[i] = tostring(select(i, ...))
  end
  return table.concat(frags, " ")
end

-- let log be a global because it's inconvenient to have to do truss.log
log = {}
log.debug = function(...) ctruss.truss_log(4, stringify_args(...)) end
log.info = function(...) ctruss.truss_log(3, stringify_args(...)) end
log.warn = function(...) ctruss.truss_log(2, stringify_args(...)) end
log.warning = log.warn
log.error = function(...) ctruss.truss_log(1, stringify_args(...)) end
log.critical = function(...) ctruss.truss_log(0, stringify_args(...)) end
truss.log = log

-- use default lua error handling
truss.error = error

-- convenience
function truss.assert(condition, error_msg)
  if not condition then 
    truss.error(error_msg or "assertion failure") 
  else 
    return condition 
  end
end

-- from luajit
ffi = require("ffi")
bit = require("bit")

truss.os = ffi.os
local library_extensions = {Windows = ".dll", Linux = ".so", OSX = ".dylib", 
                            BSD = ".so", POSIX = ".so", Other = ""}
local libary_prefixes = {Windows = "", Linux = "lib", OSX = "lib",
                         BSD = "lib", POSIX = "lib", Other = ""}
truss.library_extension = library_extensions[truss.os] or ""
truss.library_prefix = libary_prefixes[truss.os] or ""

function truss.link_library(basedir, libname)
  if not libname then
    libname, basedir = basedir, ""
  end
  if #basedir > 0 then basedir = basedir .. "/" end
  local fullpath = basedir .. truss.library_prefix .. 
                   libname .. truss.library_extension
  log.info("Linking " .. fullpath)
  terralib.linklibrary(fullpath)
end

-- timing functions
-- local t0 = tic()
-- local dt = toc(t0) -- dt is elapsed seconds as a float
truss.tic = truss.C.get_hp_time
terra truss.toc(startTime: uint64)
  var curtime = truss.C.get_hp_time()
  var freq = truss.C.get_hp_freq()
  var deltaF : float = curtime - startTime
  return deltaF / [float](freq)
end

-- register a function to be called right before truss quits
-- (e.g., openvr cleanup)
truss._cleanup_functions = {}
function truss.on_quit(f)
  truss._cleanup_functions[f] = f
end

-- sleep
function truss.sleep(ms)
  truss.C.sleep(ms)
end

-- the true quit function
local _quit_code
local function _truss_quit()
  log.info("Shutdown: calling cleanup functions")
  for _, f in pairs(truss._cleanup_functions) do f() end
  if _quit_code and type(_quit_code) == "number" then
    truss.C.set_error(_quit_code)
    log.info("Error code: [" .. tostring(_quit_code) .. "]")
  end
  truss.C.stop_interpreter(TRUSS_ID)
end

-- gracefully quit truss with an optional error code
function truss.quit(code)
  log.info("Shutdown requested from Lua")
  _quit_code = code
  _core_update = _truss_quit
  _fallback_update = _truss_quit
end

-- load an entire file into memory as a string (8-bit clean)
function truss.load_string_from_file(filename)
  local temp = truss.C.load_file(filename)
  if temp ~= nil then
    local ret = ffi.string(temp.data, temp.data_length)
    truss.C.release_message(temp)
    return ret
  else
    log.error("Unable to load " .. filename)
    return nil
  end
end
truss.load_string = truss.load_string_from_file -- alias

-- terra has issues with line numbering with dos line endings (\r\n), so
-- this function loads a string and then gets rid of carriage returns (\r)
function truss.load_script_from_file(filename)
  local s = truss.load_string_from_file(filename)
  if s then return s:gsub("\r", "") else return nil end
end

-- for debugging, get a specific line out of a script;
-- if the script doesn't exist, return nil instead of throwing
-- an error
function truss.get_script_line(filename, linenumber)
  if not truss.is_file(filename) then return nil end
  local source = truss.load_script_from_file(filename)

  -- this is basically stringutils.split but we don't want to require
  -- extra modules in the middle of an error handler
  local pos = 1
  local line = nil
  local lineidx = 0
  while lineidx < linenumber do
    local first, last = string.find(source, "\n", pos)
    if first then -- found?
      line = source:sub(pos, first-1)
      pos = last+1
      lineidx = lineidx + 1
    else
      line = source:sub(pos)
      break
    end
  end
  return line
end

-- terralib.loadstring does not take a name parameter (which is needed
-- to get reasonable error messages), so we have to perform this workaround
-- to use the lower-level terralib.load which does take a name
function truss.load_named_string(str, strname, loader)
  -- create a function which returns str on the first call
  -- and nil on the second (to let terralib.load know it is done)
  local s = str
  local generator_func = function()
    local s2 = s
    s = nil
    return s2
  end
  loader = loader or terralib.load
  return loader(generator_func, '@' .. strname)
end

local function extend_table(dest, ...)
  for idx = 1, select("#", ...) do
    local addition = select(idx, ...)
    for k,v in pairs(addition) do dest[k] = v end
  end
  return dest
end
truss.extend_table = extend_table
truss.copy_table = function(t) return extend_table({}, t) end

local function slice_table(src, start_idx, stop_idx)
  local dest = {}
  if stop_idx < 0 then
    stop_idx = #src + 1 + stop_idx
  end
  for i = start_idx, stop_idx do
    dest[i - start_idx + 1] = src[i]
  end
  return dest
end
truss.slice_table = slice_table

truss._module_env = extend_table({}, _G)
local disallow_globals_mt = {
  __newindex = function (t,k,v)
    truss.error("Module " .. t._module_name .. " tried to create global '" .. k .. "'")
  end,
  __index = function (t,k)
    truss.error("Module " .. t._module_name .. " tried to access nil global '" .. k .. "'")
  end
}

function truss.set_app_directories(orgname, appname)
  truss.error("Not updated yet")
  if (not orgname) or (not appname) then
    truss.error("Must specify both org and app names.")
    return
  end 
  local sdl = require("input/sdl.t")
  local userpath = sdl.create_user_path(orgname, appname)
  log.info("Setting save dir to: " .. userpath)
  truss.C.set_raw_write_dir(userpath)
  truss.absolute_data_path = userpath
  return userpath
end

function truss.list_directory(path)
  if type(path) == 'table' then
    path = table.concat(path, '/')
  end
  local nresults = truss.C.list_directory(TRUSS_ID, path)
  if nresults < 0 then return nil end
  local ret = {}
  for i = 1, nresults do
    -- C api is 0 indexed
    ret[i] = ffi.string(truss.C.get_string_result(TRUSS_ID, i - 1))
  end
  truss.C.clear_string_results(TRUSS_ID)
  return ret
end

function truss.extract_from_archive(src_path, dest_path)
  if not (truss.is_file(src_path) and truss.is_archived(src_path)) then
    truss.error(src_path .. " is not a file or is not in archive!")
  end
  local temp = truss.C.load_file(src_path)
  if not temp then truss.error("Error reading " .. src_path) end
  truss.C.save_file(dest_path, temp)
  truss.C.release_message(temp)
end

function truss.is_file(path)
  if type(path) == 'table' then
    path = table.concat(path, '/')
  end
  return truss.C.check_file(path) == 1
end

function truss.is_directory(path)
  if type(path) == 'table' then
    path = table.concat(path, '/')
  end
  return truss.C.check_file(path) == 2
end

-- returns true if the file exists and is inside an archive
function truss.is_archived(path)
  local rawpath = truss.C.get_file_real_path(path)
  if not rawpath then return false end
  local pathstr = ffi.string(rawpath)
  local ext = string.sub(pathstr, -4)
  return ext == ".zip" 
end

function truss.save_string(filename, s)
  truss.C.save_data(filename, s, #s)
end

function truss.save_data(filename, data, datasize)
  local dtype = terralib.type(data)
  if dtype == "cdata" then
    local ttype = terralib.typeof(data)
    if ttype:isarray() then
      local dsize = terralib.sizeof(ttype) * ttype.N
      if not datasize then datasize = dsize end
      if datasize > dsize then
        truss.error("Provided datasize is too large! " .. datasize .. " > " .. dsize)
      end
    end
    truss.C.save_data(filename, terralib.cast(&int8, data), datasize)
  elseif dtype == "string" then
    truss.save_string(filename, data:sub(1, datasize))
  else
    truss.error("Only CDATA and strings can be saved, got [" .. dtype .. "]")
  end
end

local function find_path(file_name)
  local spos = 0
  for i = #file_name, 1, -1 do
    if file_name:sub(i, i) == "/" then
      spos = i - 1
      break
    end
  end
  return file_name:sub(1, spos)
end

local function expand_name(name, path)
  if name:sub(1,2) == "./" then
    return path .. "/" .. name:sub(3)
  elseif name:sub(1,1) == "/" then
    return name:sub(2)
  else
    return name
  end
end

local function create_module_require(path)
  return function(_modname, options)
    local expanded_name = expand_name(_modname, path)
    return truss.require(expanded_name, options)
  end
end

local function create_module_env(module_name, file_name, options)
  local modenv = extend_table({}, truss._module_env)
  modenv._module_name = module_name
  local path = find_path(file_name)
  modenv._path = path
  modenv._modroot = false
  modenv.require = create_module_require(path)
  modenv._env = modenv
  if not options.allow_globals then
    setmetatable(modenv, disallow_globals_mt)
  end
  return modenv
end

truss.loaders = {
  [".t"] = terralib.load,
  [".lua"] = load,
  [".moon"] = function(...) 
    return truss.require("moonscript").load(...)
  end
}

function truss.select_loader(fn)
  for extension, loader in pairs(truss.loaders) do
    if fn:sub(-(#extension)) == extension then 
      return loader 
    end
  end
  return truss.loaders.default
end

local loaded_libs = {}
truss._loaded_libs = loaded_libs
truss._script_path = "scripts/"

function truss.require(modname, options)
  options = options or {}
  if type(options) == 'boolean' then
    truss.error("Require now takes options table: require(fn, {force=true})")
  end
  if loaded_libs[modname] == false then
    truss.error("require [" .. modname .. "] : cyclical require")
    return nil
  end
  if loaded_libs[modname] == nil or options.force then
    local oldmodule = loaded_libs[modname] -- only relevant if force==true
    loaded_libs[modname] = false -- prevent possible infinite recursion

    -- if the filename is actually a directory, try to load init.t
    local filename = modname
    local fullpath = truss._script_path .. filename
    if truss.C.check_file(fullpath) == 2 then
      fullpath = fullpath .. "/init.t"
      filename = filename .. "/init.t"
      log.info("Required directory; trying to load [" .. fullpath .. "]")
    end

    local t0 = truss.tic()
    local funcsource = truss.load_script_from_file(fullpath)
    if not funcsource then
      truss.error("require('" .. filename .. "'): file does not exist.")
      return nil
    end
    local loader = truss.select_loader(fullpath)
    if not loader then
      truss.error("No loader for " .. fullpath)
    end
    local module_def, loaderror = truss.load_named_string(funcsource, filename, loader)
    if not module_def then
      truss.error("require('" .. modname .. "'): syntax error: " .. loaderror)
      return nil
    end
    local modenv = options.env or create_module_env(modname, filename, options)
    rawset(modenv, "_preregister", function(v)
      if loaded_libs[modname] then
        truss.error("Multiple preregs for [" .. modname .. "]")
      end
      loaded_libs[modname] = v
      return v
    end)
    setfenv(module_def, modenv)
    local evaluated_module = module_def()
    rawset(modenv, "_preregister", nil)
    if not (evaluated_module or options.allow_globals) then 
      truss.error("Module [" .. modname .. "] did not return a table!")
    end
    local modtab = evaluated_module or modenv
    if loaded_libs[modname] and (loaded_libs[modname] ~= modtab) then
      truss.error("Module [" .. modname .. "] did not return preregistered table!")
    end
    loaded_libs[modname] = modtab
    log.info(string.format("Loaded [%s] in %.2f ms",
                          modname, truss.toc(t0) * 1000.0))
  end
  return loaded_libs[modname]
end
truss._module_env.require = truss.require

function truss.check_module_exists(filename)
  if loaded_libs[filename] then return true end
  local fullpath = truss._script_path .. filename
  return truss.C.check_file(fullpath) ~= 0
end

function truss.require_as(filename, libname, options)
  log.info("Loading [" .. filename .. "] as [" .. libname .. "]")
  local temp = truss.require(filename, options)
  loaded_libs[libname] = temp
  return temp
end

-- just directly inserts a module
function truss.insert_module(libname, libtable)
  loaded_libs[libname] = libtable
end

-- alias standard lua/luajit libraries so they can be 'required'
truss.insert_module("ffi", ffi)
truss.insert_module("bit", bit)
truss.insert_module("string", string)
truss.insert_module("io", io)
truss.insert_module("os", os)
truss.insert_module("table", table)
-- hmmm: should 3rd party libraries requiring math get truss math?
truss.insert_module("luamath", math)
truss.insert_module("package", package)
truss.insert_module("debug", debug)
truss.insert_module("coroutine", coroutine)
truss.insert_module("jit", jit)

-- alias core/30log.lua to class so we can just require("class")
truss.require_as("core/30log.lua", "class")

local vstr = ffi.string(truss.C.get_version())
truss.BIN_VERSION = vstr
truss.LIB_VERSION = "0.2.0"
truss.VERSION = truss.BIN_VERSION

local modutils = truss.require("core/module.t")
modutils.reexport(truss.require("core/memory.t"), truss)

-- replace lua require with truss require
lua_require = require
require = truss.require

-- read out command line arguments into a convenient table
truss.args = {}
local idx = 0
while true do
  local argname = "arg" .. idx
  local argval = truss.C.get_store_value(argname)
  if argval == nil then break end
  local argstr = ffi.string(argval.data, argval.data_length)
  log.debug(argname .. ": " .. argstr)
  table.insert(truss.args, argstr)
  idx = idx + 1
end
log.debug("Loaded " .. idx .. " args.")

-- mount command line argument paths into physfs
local function add_paths()
  local nargs = #(truss.args)
  for i = 3,nargs do
    if truss.args[i] == "--addpath" and i+2 <= nargs then
      local physicalPath = truss.args[i+1]
      local mountPath = truss.args[i+2]
      log.info(("Adding path %s => %s"):format(physicalPath, mountPath))
      truss.C.add_fs_path(physicalPath, mountPath, 0, 0)
    end
  end
end

-- create some environments
truss.clean_subenv = extend_table({}, _G)
truss.mainenv = extend_table({}, _G)
truss.mainenv._env = truss.mainenv
extend_table(truss._module_env, _G)

-- use stack trace plus if it's available
if false and truss.check_module_exists("lib/StackTracePlus.lua") then
  log.debug("Using StackTracePlus for stacktraces")
  debug.traceback = truss.require("lib/StackTracePlus.lua").stacktrace
end

local function error_handler(err)
  log.critical(err)
  local trace = debug.traceback(err, 2)
  trace = trace:gsub("\r", "")
  truss.error_trace = trace
  return err
end

local function load_main(fn)
  log.info("Loading main " .. fn)
  local happy, errmsg = xpcall(truss.require, error_handler, fn, 
                               {allow_globals = true, env = truss.mainenv})
  if not happy then
    truss.enter_error_state(errmsg)
  end
  return errmsg
end

local function call_on_main(funcname, arg)
  local happy, errmsg = xpcall(truss.mainobj[funcname], error_handler, arg)
  if not happy then
    truss.enter_error_state(errmsg)
  end
end

-- These functions have to be global because
function _core_init()
  add_paths()
  local t0 = truss.tic()
  truss.mainobj = load_main("main.t")
  call_on_main("init", truss.mainobj)
  local delta = truss.toc(t0) * 1000.0
  log.info(string.format("Time to init: %.2f ms", delta))
  if not truss.mainobj.update then
    log.info("No 'update' function provided; simply quitting.")
    _core_update = function()
      truss.quit()
    end
  end
end

function _core_update()
  call_on_main("update", truss.mainobj)
end

function _fallback_update()
  truss.mainobj:fallback_update()
end

_resume_update = _core_update
function truss.enter_error_state(errmsg)
  log.warn("Entering error state: " .. errmsg)
  truss.crash_message = errmsg
  if truss.mainobj and truss.mainobj.fallback_update then
    _resume_update = _core_update
    _core_update = _fallback_update
  else
    log.info("No fallback update function present; quitting.")
    local tstr = "Traceback: " .. tostring(truss.error_trace)
    print("Runtime error. See trusslog.txt for details.")
    print(tstr)
    log.info(tstr)
    truss.quit(2001)
  end
end

function truss.resume_from_error()
  log.info("Attempting to resume from an error")
  if _resume_update then
    _core_update = _resume_update
  else
    log.warn("Cannot resume; no resume update function set.")
  end
end
