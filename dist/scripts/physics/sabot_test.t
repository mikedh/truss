-- sabot_test.t
--
-- test basic sabot functionality

local sabot = require("physics/sabot.t")
local sb = sabot.C

function float_arr(src)
  local tgt = terralib.new(float[#src])
  for i,v in ipairs(src) do
    tgt[i-1] = v
  end
  return tgt
end

function printF16(f)
  for r = 0,3 do
    local s = ""
    for c = 0,3 do
      local idx = c*4 + r
      s = s .. " " .. f[idx]
    end
    print(s)
  end
end

function init()
  ddynamicsWorld = sb.create_basic_world()
  dynamicsWorld = sb.conv_btDiscreteDynamicsWorld_to_btDynamicsWorld(ddynamicsWorld)

  gravity = float_arr{0.0, -10.0, 0.0}
  sb.btDynamicsWorld_setGravity(dynamicsWorld, gravity)

  -- create a static ground box
  groundShape = sb.create_box_shape(50.0, 50.0, 50.0)
  groundTF = float_arr{1.0, 0.0, 0.0, 0.0,
                       0.0, 1.0, 0.0, 0.0,
                       0.0, 0.0, 1.0, 0.0,
                       0.0, -56.0, 0.0, 1.0}
  groundBody = sb.create_rigid_body(groundShape, 0.0, groundTF)
  sb.btDynamicsWorld_addRigidBody(dynamicsWorld, groundBody)

  -- create a dynamic sphere to fall onto the ground
  sphereShape = sb.create_sphere_shape(1.0)
  sphereTF = float_arr{1.0, 0.0, 0.0, 0.0,
                       0.0, 1.0, 0.0, 0.0,
                       0.0, 0.0, 1.0, 0.0,
                       0.0, 10.0, 0.0, 1.0}

  sphereBody = sb.create_rigid_body(sphereShape, 1.0, sphereTF)
  sb.btDynamicsWorld_addRigidBody(dynamicsWorld, sphereBody)

  -- Do some simulation
  tempTransform = terralib.new(float[16])
  for i = 1,150 do
    sb.btDynamicsWorld_stepSimulation(dynamicsWorld, 1.0 / 60.0, 10, 1.0 / 60.0)
    sb.get_rigid_body_mstate_tf(sphereBody, tempTransform)
    print("Frame " .. i)
    printF16(tempTransform)
  end
end

function update()
  truss.quit()
end

return m
