-- LÖVE configuration for the Ludo project
-- LÖVE 11.5

function love.conf(t)
  t.identity = "love-ludo"
  t.appendidentity = false
  t.version = "11.5"

  t.window.title = "Ludo (Authoritative Multiplayer + AI)"
  t.window.width = 800
  t.window.height = 600
  t.window.minwidth = 640
  t.window.minheight = 480
  t.window.resizable = true
  t.window.vsync = 1
  t.window.msaa = 0

  -- Mobile friendly
  t.window.highdpi = true

  -- Audio defaults
  t.audio.mixwithsystem = true
end