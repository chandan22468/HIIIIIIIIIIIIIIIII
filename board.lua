-- Board module: builds and draws a Ludo-like board and provides coordinate and rules helpers.
-- The visual board is close to the classic design, but piece coordinates follow a
-- mathematically generated loop (52 main squares) for simplicity and reliability.

local Board = {
  canvas = nil,
  w = 800, h = 600,
  cx = 400, cy = 300,
  radius = 220,
  innerRadius = 160,
  homeSteps = 6,
  safeIndices = {1,9,14,22,27,35,40,48}, -- relative to red=0
  startIndexByColor = {red=0, green=13, blue=26, yellow=39},
  entryIndexByColor = {}, -- filled in init
  squareRadius = 16,
  players = nil
}

local TWO_PI = math.pi * 2

local colorRGB = {
  red = {0.85, 0.2, 0.2},
  green = {0.2, 0.75, 0.3},
  blue = {0.2, 0.45, 0.9},
  yellow = {0.95, 0.85, 0.2}
}

local function deepcopy(t)
  local o = {}
  for k,v in pairs(t) do
    if type(v) == "table" then
      o[k] = deepcopy(v)
    else
      o[k] = v
    end
  end
  return o
end

-- Convert index (0..51) to an angle on the ring, starting at the bottom middle and going CCW.
local function indexToAngle(i)
  -- Start at bottom center (-pi/2), CCW so increasing angle
  return -math.pi/2 + (i / 52) * TWO_PI
end

function Board:init()
  local w, h = love.graphics.getDimensions()
  self.w, self.h = w, h
  self.cx, self.cy = w/2, h/2
  self.radius = math.min(w, h) * 0.36
  self.innerRadius = self.radius - 60
  self.squareRadius = math.max(12, math.floor(math.min(w,h)*0.022))

  -- Home-entry indices per color (chosen to meet spec and play well)
  -- A piece moves into the home stretch when it moves exactly
  -- stepsNeeded = distance(current, entryIndex[color]) + 1
  -- We define entryIndex[color] = (start + 50) % 52
  self.entryIndexByColor.red = (self.startIndexByColor.red + 50) % 52
  self.entryIndexByColor.green = (self.startIndexByColor.green + 50) % 52
  self.entryIndexByColor.blue = (self.startIndexByColor.blue + 50) % 52
  self.entryIndexByColor.yellow = (self.startIndexByColor.yellow + 50) % 52

  -- Static board canvas
  self.canvas = love.graphics.newCanvas(w, h)
  self:drawStatic()
end

function Board:reset(players)
  self.players = players
end

function Board:isSafe(index)
  -- index is 0..51
  local rel = (index - self.startIndexByColor.red) % 52
  for _, s in ipairs(self.safeIndices) do
    if rel == s then return true end
  end
  return false
end

function Board:isHomeEntry(index, color)
  return index == self.entryIndexByColor[color]
end

-- Convert a piece table to XY on screen.
-- piece has fields: yard (bool), pathIndex (0..51 or nil), homeIndex (0..5 or nil), finished (bool)
function Board:posToXY(piece, playerColor)
  if piece.finished then
    -- Finished pieces rest in the center triangle area for their color
    local dirs = {
      red = {0, -1},
      green = {1, 0},
      blue = {0, 1},
      yellow = {-1, 0}
    }
    local dx, dy = unpack(dirs[playerColor] or {0, -1})
    local fx = self.cx + dx * 30 + (piece.finishSlot or 0) * 4
    local fy = self.cy + dy * 30 + (piece.finishSlot or 0) * 4
    return fx, fy, true
  end

  if piece.yard then
    -- Place inside the colored yard in a 2x2 grid
    local gridPos = {
      red = {x = self.cx - self.radius - 90, y = self.cy + self.radius - 90},
      green = {x = self.cx - self.radius - 90, y = self.cy - self.radius - 90},
      blue = {x = self.cx + self.radius - 90, y = self.cy + self.radius - 90},
      yellow = {x = self.cx + self.radius - 90, y = self.cy - self.radius - 90},
    }
    local base = gridPos[playerColor]
    if not base then return end
    local idx = (piece.slot or 1) - 1
    local gx = idx % 2
    local gy = math.floor(idx / 2)
    local x = base.x + gx * 36
    local y = base.y + gy * 36
    return x, y, false
  end

  if piece.pathIndex ~= nil then
    local ang = indexToAngle(piece.pathIndex)
    local r = self.radius
    local x = self.cx + math.cos(ang) * r
    local y = self.cy + math.sin(ang) * r
    return x, y, false
  end

  if piece.homeIndex ~= nil then
    -- Move along a straight line from ring to center depending on color
    local colorDir = {
      red = {0, -1, anchor = -math.pi/2},    -- from bottom towards center (up)
      green = {1, 0, anchor = math.pi},      -- from left towards center (right)
      blue = {0, 1, anchor = math.pi/2},     -- from top towards center (down)
      yellow = {-1, 0, anchor = 0},          -- from right towards center (left)
    }
    local d = colorDir[playerColor]
    if not d then return end
    local step = piece.homeIndex -- 0..5
    local spacing = (self.radius - self.innerRadius) / (self.homeSteps + 1)
    local startR = self.radius - spacing
    local x = self.cx + math.cos(d.anchor) * (startR - step * spacing)
    local y = self.cy + math.sin(d.anchor) * (startR - step * spacing)
    return x, y, true
  end
end

-- Count pieces on a main-path index and return map owner->count and list of pieces
function Board:countAtIndex(index)
  local counts = {}
  local pieces = {}
  if not self.players then return counts, pieces end
  for _, p in ipairs(self.players) do
    for i, pc in ipairs(p.pieces) do
      if pc.pathIndex == index then
        counts[p.color] = (counts[p.color] or 0) + 1
        table.insert(pieces, {player=p, piece=pc, pieceID=i})
      end
    end
  end
  return counts, pieces
end

-- Validate move for a player's piece and a step count.
-- Returns: isValid, reason, outcome
-- outcome = {targetIndex=?, willEnterHome=?, homeIndex=?, knockTarget={playerSeat,pieceID}}
function Board:validateMove(player, pieceID, steps)
  local piece = player.pieces[pieceID]
  if not piece then return false, "invalid_piece" end
  if piece.finished then return false, "already_finished" end
  if steps <= 0 then return false, "invalid_steps" end

  local startIndex = self.startIndexByColor[player.color]
  local entryIndex = self.entryIndexByColor[player.color]

  -- Piece in yard requires a 6 to enter
  if piece.yard then
    if steps ~= 6 then
      return false, "need_six_to_leave_yard"
    end
    local targetIndex = startIndex
    local counts = self:countAtIndex(targetIndex)
    -- Landing on opponent's block (2 or more) is not allowed
    for color, cnt in pairs(counts) do
      if color ~= player.color and cnt >= 2 then
        return false, "blocked_start_square"
      end
    end
    -- Moving to start always allowed, may knock a single opponent
    local knock = nil
    if not self:isSafe(targetIndex) then
      local _, pieces = self:countAtIndex(targetIndex)
      if #pieces == 1 and pieces[1].player.color ~= player.color then
        knock = {playerSeat = pieces[1].player.seat, pieceID = pieces[1].pieceID}
      elseif #pieces >= 2 and pieces[1].player.color ~= player.color then
        return false, "opponent_block"
      end
    end
    return true, nil, {targetIndex = targetIndex, willEnterHome=false, homeIndex=nil, knockTarget=knock}
  end

  -- On main path
  if piece.pathIndex ~= nil then
    local cur = piece.pathIndex
    -- Steps to enter home stretch
    local stepsToEnter = ((entryIndex - cur + 52) % 52) + 1
    if steps < stepsToEnter then
      local targetIndex = (cur + steps) % 52
      local counts = self:countAtIndex(targetIndex)
      for color, cnt in pairs(counts) do
        if color ~= player.color and cnt >= 2 then
          return false, "opponent_block"
        end
      end
      local knock = nil
      if not self:isSafe(targetIndex) then
        local _, pieces = self:countAtIndex(targetIndex)
        if #pieces == 1 and pieces[1].player.color ~= player.color then
          knock = {playerSeat = pieces[1].player.seat, pieceID = pieces[1].pieceID}
        elseif #pieces >= 2 and pieces[1].player.color ~= player.color then
          return false, "opponent_block"
        end
      end
      return true, nil, {targetIndex = targetIndex, willEnterHome=false, homeIndex=nil, knockTarget=knock}
    else
      -- Entering home stretch
      local leftover = steps - stepsToEnter
      if leftover > self.homeSteps - 1 then
        return false, "overshoot_home"
      end
      local homeIndex = leftover
      -- Exact movement inside home (cannot overshoot beyond last cell)
      return true, nil, {targetIndex=nil, willEnterHome=true, homeIndex=homeIndex}
    end
  end

  -- Inside home stretch
  if piece.homeIndex ~= nil then
    local targetHome = piece.homeIndex + steps
    if targetHome > self.homeSteps - 1 then
      return false, "overshoot_finish"
    end
    return true, nil, {targetIndex=nil, willEnterHome=true, homeIndex=targetHome}
  end

  return false, "invalid_state"
end

-- Apply a move that has been validated.
-- Returns events: {knock={seat,pieceID}, enteredHome=true/false, finishedPiece=true/false, winner=seatOrNil}
function Board:applyMove(player, pieceID, steps)
  local valid, reason, outcome = self:validateMove(player, pieceID, steps)
  if not valid then
    return false, reason
  end

  local ev = {enteredHome=false, finishedPiece=false, knock=nil, winner=nil}

  local piece = player.pieces[pieceID]

  if piece.yard then
    piece.yard = false
    piece.pathIndex = outcome.targetIndex
  elseif piece.pathIndex ~= nil then
    if outcome.willEnterHome then
      piece.pathIndex = nil
      piece.homeIndex = outcome.homeIndex
      ev.enteredHome = true
    else
      piece.pathIndex = outcome.targetIndex
    end
  elseif piece.homeIndex ~= nil then
    piece.homeIndex = outcome.homeIndex
  end

  -- Apply knock if any
  if outcome.knockTarget then
    local opp = nil
    for _, p in ipairs(self.players or {}) do
      if p.seat == outcome.knockTarget.playerSeat then
        opp = p
        break
      end
    end
    if opp then
      local knockedPiece = opp.pieces[outcome.knockTarget.pieceID]
      if knockedPiece then
        knockedPiece.yard = true
        knockedPiece.pathIndex = nil
        knockedPiece.homeIndex = nil
        knockedPiece.finished = false
        ev.knock = {seat = opp.seat, pieceID = outcome.knockTarget.pieceID}
      end
    end
  end

  -- Finished piece?
  if piece.homeIndex ~= nil and piece.homeIndex == self.homeSteps - 1 then
    piece.homeIndex = nil
    piece.finished = true
    piece.finishSlot = (player:finishedCount() or 0)
    ev.finishedPiece = true
  end

  -- Winner?
  if player:finishedCount() == 4 then
    ev.winner = player.seat
  end

  return true, ev
end

-- Draw static board to canvas for performance
function Board:drawStatic()
  love.graphics.setCanvas(self.canvas)
  love.graphics.clear(0.12,0.12,0.14,1)

  local cx, cy = self.cx, self.cy
  local r = self.radius
  local inner = self.innerRadius

  -- Outer ring (track)
  love.graphics.setColor(0.24,0.24,0.26)
  love.graphics.circle("fill", cx, cy, r + 34)
  love.graphics.setColor(0.1,0.1,0.12)
  love.graphics.circle("fill", cx, cy, inner - 34)

  -- Colored yards (corners)
  local yd = 150
  local function rect(x,y,w,h,col)
    love.graphics.setColor(col[1], col[2], col[3], 0.85)
    love.graphics.rectangle("fill", x, y, w, h, 8, 8)
    love.graphics.setColor(0,0,0,0.22)
    love.graphics.rectangle("line", x, y, w, h, 8, 8)
  end
  rect(cx - r - 120, cy - r - 120, yd, yd, colorRGB.green)
  rect(cx + r - 30,  cy - r - 120, yd, yd, colorRGB.yellow)
  rect(cx - r - 120, cy + r - 30,  yd, yd, colorRGB.red)
  rect(cx + r - 30,  cy + r - 30,  yd, yd, colorRGB.blue)

  -- Center triangles (home)
  local function tri(col, points)
    love.graphics.setColor(col)
    love.graphics.polygon("fill", points)
    love.graphics.setColor(0,0,0,0.25)
    love.graphics.polygon("line", points)
  end
  tri(colorRGB.red,    {cx,cy,  cx-30,cy+30,  cx+30,cy+30})
  tri(colorRGB.green,  {cx,cy,  cx-30,cy-30,  cx-30,cy+30})
  tri(colorRGB.blue,   {cx,cy,  cx+30,cy+30,  cx+30,cy-30})
  tri(colorRGB.yellow, {cx,cy,  cx-30,cy-30,  cx+30,cy-30})

  -- Safe stars on ring positions
  love.graphics.setColor(1,1,1,0.85)
  for _, rel in ipairs(self.safeIndices) do
    local idx = (self.startIndexByColor.red + rel) % 52
    local ang = -math.pi/2 + (idx / 52) * TWO_PI
    local x = cx + math.cos(ang) * r
    local y = cy + math.sin(ang) * r
    local s = 8
    local star = {}
    for i=1,5 do
      local a = ang + (i-1)*2*math.pi/5
      local ox = math.cos(a) * s
      local oy = math.sin(a) * s
      table.insert(star, x+ox); table.insert(star, y+oy)
    end
    love.graphics.circle("fill", x, y, 6)
  end

  love.graphics.setCanvas()
end

function Board:draw()
  local w, h = love.graphics.getDimensions()
  if (self.canvas:getWidth() ~= w or self.canvas:getHeight() ~= h) then
    -- Rebuild on resize
    self:init()
  end
  love.graphics.setColor(1,1,1,1)
  love.graphics.draw(self.canvas, 0, 0)

  -- Draw the main path squares
  local r = self.radius
  for i = 0, 51 do
    local ang = -math.pi/2 + (i / 52) * TWO_PI
    local x = self.cx + math.cos(ang) * r
    local y = self.cy + math.sin(ang) * r
    love.graphics.setColor(0.18,0.18,0.2)
    love.graphics.circle("fill", x, y, self.squareRadius)
    love.graphics.setColor(0,0,0,0.2)
    love.graphics.circle("line", x, y, self.squareRadius)
  end

  -- Home stretches
  local colToDir = {
    red    = -math.pi/2,
    green  = math.pi,
    blue   = math.pi/2,
    yellow = 0
  }
  for col, ang in pairs(colToDir) do
    for i=0,self.homeSteps-1 do
      local spacing = (self.radius - self.innerRadius) / (self.homeSteps + 1)
      local startR = self.radius - spacing
      local rr = startR - i * spacing
      local x = self.cx + math.cos(ang) * rr
      local y = self.cy + math.sin(ang) * rr
      love.graphics.setColor(0.16,0.16,0.18)
      love.graphics.circle("fill", x, y, self.squareRadius-2)
      love.graphics.setColor(colorRGB[col])
      love.graphics.circle("line", x, y, self.squareRadius-2)
    end
  end
end

return Board