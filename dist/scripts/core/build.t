-- building/cross-compilation functions
local m = {}

function m.is_native()
  return (not _modroot) or (_modroot.cross_target == nil)
end

function m.target_name()
  if m.is_native() then
    return truss.os
  else
    return _modroot.cross_target_name or "Unknown"
  end
end

function m.includec(filename, args, target)
  if not m.is_native() then
    assert(target == nil, "cannot cross-compile within a cross-compilation context!")
    args = _modroot.cross_args
    target = _modroot.cross_target
  end
  print("including c [native? ", m.is_native(), "]: ", filename)
  return terralib.includec(filename, args, target)
end

function m.includecstring(str, args, target)
  if not m.is_native() then
    assert(target == nil, "cannot cross-compile within a cross-compilation context!")
    args = _modroot.cross_args
    target = _modroot.cross_target
  end
  print("including cstr [native? ", m.is_native(), "]: ", str:sub(1, 80))
  return terralib.includecstring(str, args, target)
end

function m.linklibrary(fn)
  if not m.is_native() then return end
  return terralib.linklibrary(fn)
end

function m.truss_link_library(...)
  if not m.is_native() then return end
  return truss.link_library(...)
end

function m.create_cross_compilation_root(options)
  local resolve = require("core/resolve.t")
  local root = resolve.create_root{
    module_env = truss.clean_subenv
  }
  root.cross_args = options.include_args
  root.cross_target = options.target
  root.cross_target_name = options.target_name
  return root
end

return m
