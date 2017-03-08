-- sabot.t
--
-- bindings for sabot/bullet

local modutils = require("core/module.t")
local class = require("class")
local math = require("math")

local m = {}

terralib.linklibrary("sabot")
local sabot_ = terralib.includec("sabot.h")
local sabot_c = {}

modutils.reexport_without_prefix(sabot_, "sb_", sabot_c)
modutils.reexport_without_prefix(sabot_, "bt", sabot_c) -- e.g., btRigidBody

local class_info = {
  CollisionObject = {short_name = "CO", manual = true},
  RigidBody = {parent = "CollisionObject", short_name = "RB"},
  DynamicsWorld = {short_name = "DW", manual = true},
  CollisionShape = {short_name = "CS", manual = true}
}

local _RigidBody = class("RigidBody")
m._RigidBody = _RigidBody
modutils.wrap_member_funcs(sabot_c, _RigidBody, "btRigidBody_", "ptr_RB")

function _RigidBody:init(ptr)
  if not ptr then truss.error("RigidBody requires a raw ptr!") end
  self.ptr_RB = ptr
  self._matrix = math.Matrix4():identity()
end

function _RigidBody:matrix()
  sabot_c.get_rigid_body_mstate_tf(self.ptr_RB, self._matrix.data)
  return self._matrix
end

function m.RigidBody(shape, mass, mtx)
  if not shape.ptr_CS or not mtx.data then
    truss.error("either shape is not a CollisionShape or mtx is not a Matrix")
    return nil
  end
  local ptr = sabot_c.create_rigid_body(shape.ptr_CS, mass, mtx.data)
  return _RigidBody(ptr)
end

local _CollisionShape = class("CollisionShape")
m._CollisionShape = _CollisionShape
modutils.wrap_member_funcs(sabot_c, _CollisionShape, "btCollisionShape_", "ptr_CS")

function _CollisionShape:init(ptr)
  if not ptr then truss.error("CollisionShape requires a raw ptr!") end
  self.ptr_CS = ptr
end

function m.SphereShape(rad)
  local ptr = sabot_c.create_sphere_shape(rad)
  return _CollisionShape(ptr)
end

function m.BoxShape(x, y, z)
  local ptr = sabot_c.create_box_shape(x or 0.5, y or x or 0.5, z or x or 0.5)
  return _CollisionShape(ptr)
end

-- for classname, info in pairs(class_info) do
--   if not info.manual then
--     local new_class
--     if info.parent then
--       new_class = m[info.parent]:extend(classname)
--
--     else
--       new_class = class(classname)
--     end
--     m[classname] = new_class
--   end
-- end

m.C = sabot_c

return m
