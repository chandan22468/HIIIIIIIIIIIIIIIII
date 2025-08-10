-- Authoritative networking with lua-enet when available and a robust local fallback.
-- Port: 6789
-- Message format: compact JSON via love.data.encode/decode
-- Types:
--  join_request {room, name}
--  join_response {ok, players}
--  state_update {state, turn, dice={value}, players=[...], room, winner}
--  roll_request {playerID}
--  move_request {playerID, pieceID, steps}  pieceID=-1 means "pass/no-move"
--  chat {from, text}

local enetAvailable, enet = pcall(require, "enet")

local board = require("board")
local Player = require("player")
local dice = require("dice")

local M = {
  mode = "local", -- local | host | client
  host = nil,     -- enet.host or local host object
  peer = nil,     -- client peer
  roomCode = "",
  port = 6789,
  maxPlayers = 4,
  players = {},
  youSeat = 1,
  turn = 1,
  state = "menu",
  diceValue = nil,
  callbacks = {},
  serverSeed = nil,
  lastActionTime = love.timer.getTime(),
}

local function now() return love.timer.getTime() end

local function jencode(tbl) return love.data.encode("string", "json", tbl) end
local function jdecode(str) return love.data.decode("string", "json", str) end

local function log(...) print("[NET]", ...) end

local function randomRoomCode()
  local chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  love.math.setRandomSeed(os.time() % 2147483647)
  local s = {}
  for i=1,6 do
    s[i] = chars:sub(love.math.random(1, #chars), love.math.random(1, #chars))
  end
  return table.concat(s)
end

local function broadcast(host, packet, reliable)
  if host and host.peers then
    for _, peer in ipairs(host.peers) do
      peer:send(packet, reliable and "reliable" or "unreliable")
    end
  end
end

local function makeSnapshot(self)
  local players = {}
  for _, p in ipairs(self.players) do
    table.insert(players, p:toSnapshot())
  end
  return {
    state = self.state,
    turn = self.turn,
    dice = {value = self.diceValue},
    players = players,
    room = self.roomCode,
    winner = self.winnerSeat
  }
end

local function setState(self, newState)
  self.state = newState
  if self.callbacks.on_info then self.callbacks.on_info("state -> "..newState) end
end

local function nextTurn(self)
  local start = self.turn
  local n = #self.players
  repeat
    self.turn = (self.turn % n) + 1
  until self.players[self.turn] ~= nil
  if self.turn ~= start then
    self.diceValue = nil
  end
end

local function currentPlayer(self)
  return self.players[self.turn]
end

local function validMovesFor(p, roll)
  return p:canMove(roll, board, M.players)
end

local function ensureAIForDisconnected(self)
  -- If hosting online and a player disappears, mark AI after a timeout
  for _, p in ipairs(self.players) do
    if p.disconnected and not p.isAI then
      p.isAI = true
      if self.callbacks.on_info then self.callbacks.on_info(p.name.." replaced with AI") end
    end
  end
end

-- Common: push authoritative snapshot to client (or locally to main)
local function deliverSnapshot(self)
  local snapshot = makeSnapshot(self)
  -- Update internal convenience turn tracker for UI helpers
  M.turn = self.turn
  if self.mode == "client" then
    -- Client shouldn't call this
    return
  end
  if self.mode == "host" and self.host and self.host.peers then
    local msg = jencode({type="state_update", payload=snapshot})
    broadcast(self.host, msg, true)
  end
  if self.callbacks.on_state then self.callbacks.on_state(snapshot) end
end

-- Local authoritative host (used for single player or fallback if enet missing)
local function startLocal(self, totalPlayers, humans)
  self.mode = "local"
  self.roomCode = "LOCAL"
  self.players = {}
  humans = math.max(1, math.min(totalPlayers or 2, humans or 1))
  totalPlayers = math.max(2, math.min(4, totalPlayers or 2))
  for i=1,totalPlayers do
    local color = ({"red","green","blue","yellow"})[((i-1)%4)+1]
    local isAI = (i > humans)
    local name = isAI and ("CPU "..i) or (i==1 and "You" or ("Player "..i))
    local p = Player.new{color=color, seat=i, name=name, isAI=isAI}
    table.insert(self.players, p)
  end
  self.youSeat = 1
  self.turn = 1
  self.diceValue = nil
  self.serverSeed = os.time() % 2147483647
  setState(self, "game")
  board:reset(self.players)
  deliverSnapshot(self)
end

-- Start online server
local function startHost(self, totalPlayers)
  self.mode = "host"
  self.roomCode = randomRoomCode()
  self.maxPlayers = totalPlayers or 4
  self.players = {}
  self.turn = 1
  self.diceValue = nil
  self.serverSeed = os.time() % 2147483647

  if enetAvailable then
    self.host = enet.host_create(("*:%d"):format(self.port))
    self.host.roomCode = self.roomCode
    self.host.peers = {}
    log("Hosting on port", self.port, "room", self.roomCode)
  else
    log("ENet not available; running in local-only mode")
  end
  setState(self, "lobby")
  deliverSnapshot(self)
end

-- Connect client
local function connectClient(self, ip, room, name)
  if not enetAvailable then
    if self.callbacks.on_info then self.callbacks.on_info("ENet not available. Use Single Player or Create Room on this machine.") end
    return
  end
  self.mode = "client"
  local addr = ("%s:%d"):format(ip, self.port)
  self.host = enet.host_create()
  self.peer = self.host:connect(addr)
  self.roomCode = room
  self.youSeat = nil
  self.diceValue = nil
  setState(self, "lobby")

  -- Send join request when connected
  self.pendingJoin = {room=room, name=name or "Guest"}
end

-- Server authoritative roll
local function serverRoll(self, seat)
  if self.turn ~= seat then return end
  local seed = (self.serverSeed + math.floor(now()*1000)) % 2147483647
  local value = dice.roll(seed)
  self.diceValue = value
  self.lastActionTime = now()
  -- If no valid moves -> pass turn immediately (even with 6)
  local p = self.players[self.turn]
  local valid = validMovesFor(p, value)
  if #valid == 0 then
    nextTurn(self)
  end
  deliverSnapshot(self)
end

-- Server authoritative move
local function serverMove(self, seat, pieceID, steps)
  if self.turn ~= seat then return end
  local p = self.players[seat]
  if not self.diceValue or steps ~= self.diceValue then return end

  if pieceID == -1 then
    -- client says pass (no moves)
    nextTurn(self)
    self.diceValue = nil
    deliverSnapshot(self)
    return
  end

  local ok, reason = board:applyMove(p, pieceID, steps)
  if not ok then
    if self.callbacks.on_info then self.callbacks.on_info("Invalid move: "..tostring(reason)) end
    return
  end

  self.lastActionTime = now()

  -- Check winner
  if p:finishedCount() == 4 then
    self.winnerSeat = seat
    self.state = "end"
    self.diceValue = nil
    deliverSnapshot(self)
    return
  end

  -- Extra turn on rolling a 6
  if self.diceValue ~= 6 then
    nextTurn(self)
  else
    -- keep same turn but clear dice for next roll
  end

  self.diceValue = nil
  deliverSnapshot(self)
end

-- Handle incoming packets (host side)
local function handleHostPacket(self, event)
  local msg = jdecode(event.data)
  if not msg or not msg.type then return end
  if msg.type == "join_request" then
    if self.state ~= "lobby" then
      event.peer:send(jencode({type="join_response", payload={ok=false, reason="not_in_lobby"}}), "reliable")
      return
    end
    if #self.players >= self.maxPlayers then
      event.peer:send(jencode({type="join_response", payload={ok=false, reason="room_full"}}), "reliable")
      return
    end
    -- Assign seat
    local seat = #self.players + 1
    local color = ({"red","green","blue","yellow"})[((seat-1)%4)+1]
    local p = Player.new{color=color, seat=seat, name=msg.payload.name or ("P"..seat), isAI=false}
    table.insert(self.players, p)
    table.insert(self.host.peers, event.peer)
    event.peer:send(jencode({type="join_response", payload={ok=true, seat=seat, room=self.roomCode}}), "reliable")
    deliverSnapshot(self)
  elseif msg.type == "chat" then
    broadcast(self.host, event.data, true)
    if self.callbacks.on_chat then self.callbacks.on_chat(msg.payload) end
  elseif msg.type == "roll_request" then
    serverRoll(self, msg.payload.playerID)
  elseif msg.type == "move_request" then
    serverMove(self, msg.payload.playerID, msg.payload.pieceID, msg.payload.steps)
  elseif msg.type == "ready" then
    -- unused in this simplified flow
  end
end

-- Handle incoming packets (client side)
local function handleClientPacket(self, event)
  local msg = jdecode(event.data)
  if not msg or not msg.type then return end
  if msg.type == "join_response" then
    if msg.payload.ok then
      self.youSeat = msg.payload.seat
      if self.callbacks.on_info then self.callbacks.on_info("Joined room "..tostring(msg.payload.room).." as seat "..tostring(self.youSeat)) end
    else
      if self.callbacks.on_info then self.callbacks.on_info("Join failed: "..tostring(msg.payload.reason)) end
    end
  elseif msg.type == "state_update" then
    -- Keep a local copy of turn for helpers like isMyTurn
    M.turn = msg.payload.turn
    if self.callbacks.on_state then self.callbacks.on_state(msg.payload) end
  elseif msg.type == "chat" then
    if self.callbacks.on_chat then self.callbacks.on_chat(msg.payload) end
  end
end

-- Public API

function M.setCallbacks(cbs) M.callbacks = cbs or {} end

function M.startLocalHost(totalPlayers, humans)
  startLocal(M, totalPlayers or 2, humans or 1)
end

function M.startOnlineHost(totalPlayers)
  startHost(M, totalPlayers or 4)
end

function M.connectToHost(ip, room, name)
  connectClient(M, ip or "127.0.0.1", room or "", name or "Guest")
end

function M.leave()
  if M.mode == "client" and M.peer then
    M.peer:disconnect()
  end
  if M.host then
    if M.mode == "host" and enetAvailable then
      for _, peer in ipairs(M.host.peers or {}) do peer:disconnect() end
      M.host:destroy()
    else
      if M.peer then M.peer:disconnect() end
      M.host:destroy()
    end
  end
  M.mode = "local"
  M.host, M.peer = nil, nil
end

function M.isAuthoritative()
  return M.mode == "local" or M.mode == "host"
end

function M.getMySeat()
  return M.youSeat or 1
end

function M.isMyTurn()
  return M.turn == M.getMySeat()
end

function M.rollRequest(seat)
  if M.mode == "local" then
    serverRoll(M, seat)
  elseif M.mode == "host" then
    serverRoll(M, seat)
  elseif M.mode == "client" then
    if not M.peer then return end
    M.peer:send(jencode({type="roll_request", payload={playerID=seat}}), "reliable")
  end
end

function M.moveRequest(seat, pieceID, steps)
  if M.mode == "local" then
    serverMove(M, seat, pieceID, steps)
  elseif M.mode == "host" then
    serverMove(M, seat, pieceID, steps)
  elseif M.mode == "client" then
    if not M.peer then return end
    M.peer:send(jencode({type="move_request", payload={playerID=seat, pieceID=pieceID, steps=steps}}), "reliable")
  end
end

function M.chat(text)
  local msg = {type="chat", payload={from="you", text=text}}
  if M.mode == "client" then
    if M.peer then M.peer:send(jencode(msg), "reliable") end
  elseif M.mode == "host" and M.host then
    broadcast(M.host, jencode(msg), true)
    if M.callbacks.on_chat then M.callbacks.on_chat(msg.payload) end
  else
    if M.callbacks.on_chat then M.callbacks.on_chat({from="you", text=text}) end
  end
end

function M.update(dt)
  if M.mode == "local" then
    -- nothing else
    return
  end

  if not enetAvailable or not M.host then return end

  local event = M.host:service(0)
  while event do
    if M.mode == "host" then
      if event.type == "connect" then
        log("peer connected")
      elseif event.type == "receive" then
        handleHostPacket(M, event)
      elseif event.type == "disconnect" then
        log("peer disconnected")
        -- Mark player as AI (basic replacement)
        for _, p in ipairs(M.players) do
          if not p.isAI and p.name ~= "You" then
            p.isAI = true
            p.disconnected = true
            break
          end
        end
        ensureAIForDisconnected(M)
        deliverSnapshot(M)
      end
    elseif M.mode == "client" then
      if event.type == "connect" then
        -- Send join
        if M.pendingJoin then
          M.peer:send(jencode({type="join_request", payload=M.pendingJoin}), "reliable")
          M.pendingJoin = nil
        end
      elseif event.type == "receive" then
        handleClientPacket(M, event)
      elseif event.type == "disconnect" then
        if M.callbacks.on_info then M.callbacks.on_info("Disconnected from host") end
        if M.callbacks.on_state then
          M.callbacks.on_state({state="menu"})
        end
      end
    end
    event = M.host:service(0)
  end
end

-- Host may call when the lobby is ready to start the game
function M.startMatchIfHost()
  if M.mode == "host" then
    setState(M, "game")
    board:reset(M.players)
    deliverSnapshot(M)
  end
end

-- Host/player snapshots feed back into main through callbacks
M.onSnapshot = deliverSnapshot

return M