-- Dice module with animation and server-seed support
local dice = {
  value = nil,
  animTime = 0,
  rolling = false,
  cooldown = 0,
  lastSeed = nil,
  size = 56,
  clickableRect = {x=0,y=0,w=0,h=0},
}

local dieImages = {}
local rollSound

local function clamp(a,b,c) return math.max(b, math.min(c,a)) end

function dice.loadAssets()
  -- Try to load images/sounds; fall back to placeholders
  for i=1,6 do
    local ok, img = pcall(love.graphics.newImage, "assets/die"..i..".png")
    if ok and img then dieImages[i] = img end
  end
  local ok, snd = pcall(love.audio.newSource, "assets/roll.wav", "static")
  if ok and snd then rollSound = snd end
end

function dice.reset()
  dice.value = nil
  dice.animTime = 0
  dice.rolling = false
  dice.cooldown = 0
end

function dice.stopAnimating()
  dice.rolling = false
end

-- Server can pass a seed to ensure deterministic RNG.
function dice.roll(seed)
  if seed then
    dice.lastSeed = seed
    love.math.setRandomSeed(seed)
  end
  dice.value = love.math.random(1,6)
  dice.rolling = true
  dice.animTime = 0.6
  dice.cooldown = 0.5
  if rollSound then rollSound:stop(); rollSound:play() end
  return dice.value
end

function dice.canPlayerRoll()
  return dice.cooldown <= 0 and not dice.rolling
end

function dice.update(dt)
  if dice.animTime > 0 then
    dice.animTime = dice.animTime - dt
    if dice.animTime <= 0 then
      dice.rolling = false
    end
  end
  if dice.cooldown > 0 then
    dice.cooldown = clamp(dice.cooldown - dt, 0, 999)
  end
end

function dice.draw(x, y)
  local s = dice.size
  dice.clickableRect = {x=x, y=y, w=s, h=s}

  love.graphics.setColor(0.95,0.95,0.95)
  love.graphics.rectangle("fill", x, y, s, s, 10, 10)
  love.graphics.setColor(0,0,0,0.2)
  love.graphics.rectangle("line", x, y, s, s, 10, 10)

  local displayValue = dice.value or 6
  if dice.rolling then
    displayValue = math.floor(love.timer.getTime()*20)%6 + 1
  end

  local img = dieImages[displayValue]
  if img then
    love.graphics.setColor(1,1,1)
    love.graphics.draw(img, x + s/2 - img:getWidth()/2, y + s/2 - img:getHeight()/2, 0, 1, 1)
  else
    -- Draw pips
    love.graphics.setColor(0,0,0)
    local function pip(px,py) love.graphics.circle("fill", x + px*s, y + py*s, 4) end
    local mapping = {
      [1] = {{0.5,0.5}},
      [2] = {{0.25,0.25},{0.75,0.75}},
      [3] = {{0.25,0.25},{0.5,0.5},{0.75,0.75}},
      [4] = {{0.25,0.25},{0.75,0.25},{0.25,0.75},{0.75,0.75}},
      [5] = {{0.25,0.25},{0.75,0.25},{0.5,0.5},{0.25,0.75},{0.75,0.75}},
      [6] = {{0.25,0.25},{0.75,0.25},{0.25,0.5},{0.75,0.5},{0.25,0.75},{0.75,0.75}},
    }
    for _, p in ipairs(mapping[displayValue]) do pip(p[1], p[2]) end
  end
end

function dice.getClickableRect()
  return dice.clickableRect
end

return dice