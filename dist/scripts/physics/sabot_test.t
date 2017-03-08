-- sabot_test.t
--
-- test basic sabot functionality

local sabot = require("physics/sabot.t")
local math = require("math")
local sb = sabot.C

function float_arr(src)
  local tgt = terralib.new(float[#src])
  for i,v in ipairs(src) do
    tgt[i-1] = v
  end
  return tgt
end

function init()
  ddynamicsWorld = sb.create_basic_world()
  dynamicsWorld = sb.conv_btDiscreteDynamicsWorld_to_btDynamicsWorld(ddynamicsWorld)

  gravity = float_arr{0.0, -10.0, 0.0}
  sb.btDynamicsWorld_setGravity(dynamicsWorld, gravity)

  -- create a static ground box
  groundShape = sabot.BoxShape(50.0, 50.0, 50.0)
  groundTF = math.Matrix4():translation(math.Vector(0.0, -56.0, 0.0))
  groundBody = sabot.RigidBody(groundShape, 0.0, groundTF)
  sb.btDynamicsWorld_addRigidBody(dynamicsWorld, groundBody.ptr_RB)

  -- create a dynamic sphere to fall onto the ground
  sphereShape = sabot.SphereShape(1.0)
  sphereTF = math.Matrix4():translation(math.Vector(0.0, 10.0, 0.0))

  sphereBody = sabot.RigidBody(sphereShape, 1.0, sphereTF)
  sb.btDynamicsWorld_addRigidBody(dynamicsWorld, sphereBody.ptr_RB)

  -- Do some simulation
  for i = 1,150 do
    sb.btDynamicsWorld_stepSimulation(dynamicsWorld, 1.0 / 60.0, 10, 1.0 / 60.0)
    print("Frame " .. i)
    print(tostring(sphereBody:matrix()))
  end
end

function update()
  truss.quit()
end

return m
