-- Player module/class
-- Piece states:
--  yard = true/false
--  pathIndex = 0..51 or nil
--  homeIndex = 0..5 or nil
--  finished = boolean

local Player = {}
Player.__index = Player

local colors = {"red","green","blue","yellow"}
local startIndexByColor = {red=0, green=13, blue=26, yellow=39}

local function makePieces()
  local t = {}
  for i = 1, 4 do
    t[i] = {
      yard = true,
      pathIndex = nil,
      homeIndex = nil,
      finished = false,
      slot = i
    }
  end
  return t
end

function Player.new(o)
  local self = setmetatable({}, Player)
  self.color = o.color or colors[1]
  self.seat = o.seat or 1
  self.name = o.name or ("Player "..self.seat)
  self.isAI = o.isAI or false
  self.pieces = makePieces()
  return self
end

-- Construct from authoritative snapshot (used by client)
function Player.fromSnapshot(sp)
  local self = setmetatable({}, Player)
  self.color = sp.color
  self.seat = sp.seat
  self.name = sp.name
  self.isAI = sp.isAI
  self.pieces = {}
  for i=1,4 do
    local src = sp.pieces[i]
    self.pieces[i] = {
      yard = src.yard,
      pathIndex = src.pathIndex,
      homeIndex = src.homeIndex,
      finished = src.finished,
      slot = i,
      finishSlot = src.finishSlot
    }
  end
  return self
end

function Player:toSnapshot()
  local p = {
    color = self.color,
    seat = self.seat,
    name = self.name,
    isAI = self.isAI,
    pieces = {}
  }
  for i=1,4 do
    local s = self.pieces[i]
    p.pieces[i] = {
      yard = s.yard,
      pathIndex = s.pathIndex,
      homeIndex = s.homeIndex,
      finished = s.finished,
      finishSlot = s.finishSlot
    }
  end
  return p
end

function Player:finishedCount()
  local c = 0
  for _, pc in ipairs(self.pieces) do
    if pc.finished then c = c + 1 end
  end
  return c
end

-- Determine which pieces can move for a given roll.
-- Returns list of pieceIDs that are valid to move.
function Player:canMove(roll, board, players)
  local moves = {}
  if self:finishedCount() >= 4 then return moves end
  for i=1,4 do
    local ok, _reason = board:validateMove(self, i, roll)
    if ok then table.insert(moves, i) end
  end
  return moves
end

-- Server-side helper: move a piece after validation.
function Player:makeMove(pieceID, steps, board)
  return board:applyMove(self, pieceID, steps)
end

-- Basic deterministic AI
-- Priority:
--  1) If roll==6 and there is a yard piece, leave yard
--  2) Move that causes a knock
--  3) Move the piece furthest along (largest progress towards finish)
function Player:chooseMove(roll, board, players)
  local valid = self:canMove(roll, board, players)
  if #valid == 0 then return nil end

  -- 1) leave yard if possible with 6
  if roll == 6 then
    for _, pid in ipairs(valid) do
      local pc = self.pieces[pid]
      if pc.yard then
        return pid
      end
    end
  end

  -- 2) move that knocks
  for _, pid in ipairs(valid) do
    local ok, _, out = board:validateMove(self, pid, roll)
    if ok and out and out.knockTarget then
      return pid
    end
  end

  -- 3) move the piece with greatest progress
  local function progressOf(pc)
    if pc.finished then return 1000 end
    if pc.homeIndex ~= nil then return 100 + pc.homeIndex end
    if pc.pathIndex ~= nil then
      local start = startIndexByColor[self.color]
      local d = (pc.pathIndex - start + 52) % 52
      return d
    end
    return -1
  end

  local bestPid, bestScore = nil, -1
  for _, pid in ipairs(valid) do
    local score = progressOf(self.pieces[pid])
    if score > bestScore then bestScore = score; bestPid = pid end
  end
  return bestPid
end

return Player