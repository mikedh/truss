-- core/module.t
--
-- contains a bunch of useful functions for creating modules

local m = {}

-- copy all public exports from module srcname into destination table
-- if the returned module object has an explicit .exports, use that
function m.reexport(srcmodule, desttable)
  local src = srcmodule.exports or srcmodule
  for k,v in pairs(src) do
    if not desttable[k] then
      desttable[k] = v
    else
      truss.error("core/module.t: reexport: destination already has " .. k)
    end
  end
end

-- copy all public exports from a list of modules into a destination table
-- ex: include_submodules({"foo/bar.t", "foo/baz.t"}, foo)
function m.include_submodules(srclist, dest)
  for _,srcname in ipairs(srclist) do
    m.reexport(require(srcname), dest)
  end
end

function m.has_prefix(k, prefix)
  if k:sub(1, prefix:len()) == prefix then
    return true, k:sub(prefix:len() + 1)
  else
    return false
  end
end

-- copy values in srctable with prefix into desttable without prefix
-- useful when including a C api that has library_ prefix names on everything
function m.reexport_without_prefix(srctable, prefix, desttable)
  for k,v in pairs(srctable) do
    -- only copy entries that have prefix
    local is_prefixed, stripped_name = m.has_prefix(k, prefix)
    if is_prefixed then
      desttable[stripped_name] = v
    end
  end
end

function m.wrap_member_funcs(c_funcs, target, prefix, ctx_name)
  for func_name, func in pairs(c_funcs) do
    local is_prefixed, stripped_name = m.has_prefix(func_name, prefix)
    if is_prefixed then
      target[stripped_name] = function(self, ...)
        return func(self[ctx_name], ...)
      end
    end
  end
end

return m
