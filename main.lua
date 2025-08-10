-- Entry point
-- State machine: menu -> lobby -> game -> end
-- Modules: board, player, network, ui, dice

local board = require("board")
local Player = require("player")
local dice = require("dice")
local net = require("network")
local ui = require("ui")

local state = "menu"
local font, smallFont, monoFont

local game = {
  players = {},
  turn = 1,            -- 1..N index into game.players
  currentRoll = nil,   -- last resolved die value
  mustMove = false,    -- set after a roll when at least one move exists
  winnerSeat = nil,
  chat = {},
  youSeat = 1,         -- seat index for this local client
  roomCode = "",
  isHost = false,
  mode = "local"       -- "local" | "host" | "client"
}

local colors = {"red","green","blue","yellow"}

local function resetLocalSinglePlayer(numHumans, totalPlayers)
  game.players = {}
  for i = 1, totalPlayers do
    local color = colors[((i-1)%4)+1]
    local isAI = (i > numHumans)
    local name = isAI and ("CPU "..i) or ("Player "..i)
    table.insert(game.players, Player.new{
      color = color,
      seat = i,
      name = name,
      isAI = isAI
    })
  end
  game.turn = 1
  game.currentRoll = nil
  game.mustMove = false
  game.winnerSeat = nil
  dice.reset()
  board:reset(game.players)
end

-- Helpers
local function currentPlayer()
  return game.players[game.turn]
end

local function appendChat(from, text)
  table.insert(game.chat, {from=from, text=text, time=love.timer.getTime()})
  if #game.chat > 100 then
    table.remove(game.chat, 1)
  end
end

-- Network event handlers (client-side API surface the UI uses)
local function onStateUpdate(snapshot)
  -- Snapshot is authoritative from host
  -- Shape: {state="lobby/game/end", turn, dice, players, room, winner}
  state = snapshot.state or state
  game.roomCode = snapshot.room or game.roomCode

  -- Rebuild players from snapshot
  if snapshot.players then
    game.players = {}
    for _, sp in ipairs(snapshot.players) do
      local p = Player.fromSnapshot(sp)
      table.insert(game.players, p)
    end
  end

  board:reset(game.players)

  game.turn = snapshot.turn or game.turn
  game.currentRoll = snapshot.dice and snapshot.dice.value or nil
  game.winnerSeat = snapshot.winner or nil

  if state == "end" and game.winnerSeat then
    dice.stopAnimating()
  end
end

local function onChat(msg)
  appendChat(msg.from or "?", msg.text or "")
end

-- Init
function love.load()
  love.graphics.setBackgroundColor(0.1,0.1,0.12)
  font = love.graphics.newFont(18)
  smallFont = love.graphics.newFont(14)
  monoFont = love.graphics.newFont(14)
  love.graphics.setFont(font)

  dice.loadAssets()
  ui.init()

  -- Default local single player (1 human vs 1 AI) is ready immediately for preview
  resetLocalSinglePlayer(1, 2)
  board:init()

  -- Setup network callbacks
  net.setCallbacks{
    on_state = onStateUpdate,
    on_chat = onChat,
    on_info = function(txt) appendChat("system", txt) end
  }
end

-- Update
function love.update(dt)
  ui.updateLayout()

  dice.update(dt)

  net.update(dt)

  if state == "game" then
    -- If we are the authoritative host (or local), we can drive AI turns
    if net.isAuthoritative() then
      local p = currentPlayer()
      if p and p.isAI then
        -- Simple AI: request a roll if needed, otherwise request a move
        if not game.currentRoll and dice.canPlayerRoll() then
          net.rollRequest(p.seat)
        elseif game.currentRoll then
          -- Ask the AI to choose
          local pieceId = p:chooseMove(game.currentRoll, board, game.players)
          if pieceId then
            net.moveRequest(p.seat, pieceId, game.currentRoll)
          else
            -- No move, pass turn
            net.moveRequest(p.seat, -1, game.currentRoll) -- -1 indicates pass
          end
        end
      end
    end
  end
end

-- Draw
function love.draw()
  local w, h = love.graphics.getDimensions()

  if state == "menu" then
    ui.drawMenu(game, net)
    return
  end

  if state == "lobby" then
    ui.drawLobby(game, net)
    return
  end

  if state == "game" then
    -- Board
    board:draw()

    -- Pieces
    for _, p in ipairs(game.players) do
      for i, piece in ipairs(p.pieces) do
        local x, y, inHome = board:posToXY(piece, p.color)
        if x and y then
          ui.drawPiece(p.color, x, y, i, piece, p == currentPlayer())
        end
      end
    end

    -- HUD + Chat
    ui.drawHUD{
      game = game,
      board = board,
      dice = dice,
      net = net
    }
    return
  end

  if state == "end" then
    board:draw()
    ui.drawEnd(game, net)
  end
end

-- Input
function love.mousepressed(x, y, button)
  if state == "menu" then
    ui.mousepressedMenu(x, y, button, game, net, function(newState)
      if newState then state = newState end
    end)
    return
  end

  if state == "lobby" then
    ui.mousepressedLobby(x,y,button, game, net, function(started)
      if started then state = "game" end
    end)
    return
  end

  if state == "game" then
    -- Dice click
    if ui.hitDice(x,y) and dice.canPlayerRoll() and net.isMyTurn() then
      net.rollRequest(net.getMySeat())
      return
    end

    -- Piece selection / move
    if game.currentRoll and net.isMyTurn() then
      -- Try to click one of my pieces
      local me = game.players[net.getMySeat()]
      if me then
        for i, piece in ipairs(me.pieces) do
          local px, py = board:posToXY(piece, me.color)
          if px and (x-px)^2 + (y-py)^2 <= (ui.pieceRadius()^2) then
            net.moveRequest(me.seat, i, game.currentRoll)
            return
          end
        end
      end
    end
    ui.mousepressedHUD(x,y,button, game, net)
  end

  if state == "end" then
    if ui.buttonAt("BackToMenu") and ui.pointInRect and ui.pointInRect(x,y, ui.buttonAt("BackToMenu")) then
      state = "menu"
    end
  end
end

function love.keypressed(key)
  if key == "escape" then
    if state == "game" then
      ui.toggleChatFocus(false)
    elseif state == "lobby" then
      state = "menu"
      net.leave()
    else
      love.event.quit()
    end
  end

  ui.keypressed(key, function(cmd)
    if cmd and cmd.type == "chat" and cmd.text and cmd.text ~= "" then
      net.chat(cmd.text)
      ui.clearChatInput()
    end
  end)
end

function love.textinput(t)
  ui.textinput(t)
end

-- Public API for network snapshot to reach main
-- The host/client code calls these automatically through callbacks.
function love.handlers.state_update(payload)
  onStateUpdate(payload)
end

function love.handlers.chat_message(payload)
  onChat(payload)
end

-- Transition helpers from UI
function ui.onStartLocalGame(config)
  -- config: {humans, total}
  game.mode = "local"
  game.isHost = true
  net.startLocalHost(config.total, config.humans)
  state = "game"
end

function ui.onCreateRoom(totalPlayers)
  game.mode = "host"
  game.isHost = true
  net.startOnlineHost(totalPlayers)
  state = "lobby"
end

function ui.onJoinRoom(params)
  -- params: {ip, room, name}
  game.mode = "client"
  game.isHost = false
  net.connectToHost(params.ip, params.room, params.name or "Guest")
  state = "lobby"
end