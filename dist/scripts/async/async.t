-- async/async.t
--
-- async event loop

local class = require("class")
local promise = require("async/promise.t")
local queue = require("utils/queue.t")
local scheduler = require("async/scheduler.t")
local m = {}

function m.clear()
  m._procs = {}
  m._yield_queue = queue.Queue()
  m._resolve_queue = queue.Queue()
  m._schedule = scheduler.FrameScheduler()
end
m.clear()

local function _step(proc, args, succeeded)
  local happy, ret, immediate
  if succeeded == nil then
    happy, ret, immediate = coroutine.resume(proc.co, unpack(args))
  else
    happy, ret, immediate = coroutine.resume(proc.co, succeeded, args)
  end
  if not happy then
    m._procs[proc] = nil -- kill proc?
    proc.promise:reject(ret)
    return
  end
  if coroutine.status(proc.co) == "dead" then
    m._procs[proc] = nil
    proc.promise:resolve(ret)
  elseif ret then
    if immediate then
      ret:next(function(...)
        m._resolve_immediate(proc, ...)
      end,
      function(err)
        m._reject_immediate(proc, err)
      end)
    else
      ret:next(function(...)
        m._resolve(proc, ...)
      end,
      function(err)
        m._reject(proc, err)
      end)
    end
  else
    -- yielding nothing indicates delay for a frame
    m._yield_queue:push(proc)
  end
end

function m.schedule(n, f)
  return m._schedule:schedule(n, f)
end

function m.run(f, ...)
  local proc = {
    co = coroutine.create(f),
    promise = promise.Promise()
  }
  m._procs[proc] = proc
  _step(proc, {...})
  return proc.promise
end

function m._resolve(proc, ...)
  m._resolve_queue:push({proc, true, {...}})
end

function m._reject(proc, err)
  m._resolve_queue:push({proc, false, err})
end

function m._resolve_immediate(proc, ...)
  _step(proc, {...}, true)
end

function m._reject_immediate(proj, ...)
  _step(proc, {...}, false)
end

function m.update(maxtime)
  -- TODO: deal with maxtime

  m._schedule:update(1)

  -- only process the current number of items in the queue
  -- because processes might yield again when resumed
  local nyield = m._yield_queue:length()
  for i = 1, nyield do
    local proc = m._yield_queue:pop()
    _step(proc, {}, true)
  end

  -- handle resolves
  while m._resolve_queue:length() > 0 do
    local proc, happy, args = unpack(m._resolve_queue:pop())
    _step(proc, args, happy)
  end
end

function m.await(p, immediate)
  -- we could check if we're actually in a coroutine with
  -- coroutine.running(), and perhaps throw a more useful
  -- error message
  local happy, ret = coroutine.yield(p, immediate)
  if not happy then truss.error(ret) end
  return unpack(ret)
end

function m.await_immediate(p)
  return m.await(p, true)
end

-- protected await
function m.pawait(p, immediate)
  return coroutine.yield(p, immediate)
end

-- convenience for async.await(async.run(f, ...))
function m.await_run(f, ...)
  return m.await(m.run(f, ...))
end

function m.await_frames(n)
  if n == nil or n == 1 then
    coroutine.yield()
    return 1
  else
    return m.await(m.schedule(n))
  end
end

function m.await_condition(cond, timeout)
  local f = 0
  while not cond() do
    f = f + 1
    if timeout and f >= timeout then 
      return false 
    end
  end
  return true
end

function m.event_promise(target, event_name)
  local receiver = {}
  local p = promise.Promise(function(d)
    target:on(event_name, receiver, function(_, ename, evt)
      receiver._dead = true
      d:resolve({ename, evt}) -- TODO: fix promise to deal with multiple values?
    end)
  end)
  p.receiver = receiver -- put this somewhere so callback doesn't get GC'ed
  return p
end

-- convenience method for interacting with the callback-based event system
function m.await_event(target, event_name)
  return m.await(m.event_promise(target, event_name))
end

-- wrap a function so it is async.run'd when called  
function m.async_function(f)
  return function(...)
    return m.run(f, ...)
  end
end
m.afunc = m.async_function -- shorter alias

-- An ECS System that'll call update on the async event pump every frame
local AsyncSystem = class("AsyncSystem")
m.AsyncSystem = AsyncSystem

function AsyncSystem:init(maxtime)
  self.maxtime = maxtime
end

function AsyncSystem:update(ecs)
  m.update(self.maxtime)
end

return m