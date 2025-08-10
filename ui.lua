-- UI module: menus, lobby, HUD, and drawing helpers.

local dice = require("dice")
local utf8 = require("utf8")
local hasEnet = pcall(require, "enet")

local ui = {
  scale = 1,
  chatFocused = false,
  chatInput = "",
  cachedButtons = {}, -- id -> {x,y,w,h}
}

local colorRGB = {
  red = {0.85, 0.2, 0.2},
  green = {0.2, 0.75, 0.3},
  blue = {0.2, 0.45, 0.9},
  yellow = {0.95, 0.85, 0.2}
}

local function setFont(size)
  local f = love.graphics.newFont(size)
  love.graphics.setFont(f)
  return f
end

function ui.init() end

function ui.updateLayout()
  local w, h = love.graphics.getDimensions()
  ui.scale = math.min(1.0, math.max(0.75, math.min(w/800, h/600)))
end

function ui.buttonAt(id)
  return ui.cachedButtons[id]
end

function ui.pointInRect(x,y, r)
  return x>=r.x and x<=r.x+r.w and y>=r.y and y<=r.y+r.h
end

local function button(id, x,y,w,h,label, enabled)
  enabled = enabled ~= false
  ui.cachedButtons[id] = {x=x,y=y,w=w,h=h}
  local mx, my = love.mouse.getPosition()
  local hot = mx>=x and mx<=x+w and my>=y and my<=y+h
  love.graphics.setColor(enabled and (hot and {0.25,0.5,0.9} or {0.2,0.35,0.6}) or {0.2,0.2,0.2})
  love.graphics.rectangle("fill", x,y,w,h,8,8)
  love.graphics.setColor(1,1,1,enabled and 1 or 0.6)
  love.graphics.printf(label, x, y + h/2-8, w, "center")
  love.graphics.setColor(0,0,0,0.25)
  love.graphics.rectangle("line", x,y,w,h,8,8)
  return hot and enabled
end

local function textField(id, x,y,w,h, text, focused)
  ui.cachedButtons[id] = {x=x,y=y,w=w,h=h}
  love.graphics.setColor(0.95,0.95,0.95)
  love.graphics.rectangle("fill", x,y,w,h,6,6)
  love.graphics.setColor(0,0,0,0.2)
  love.graphics.rectangle("line", x,y,w,h,6,6)
  love.graphics.setColor(0,0,0)
  local disp = text
  love.graphics.printf(disp, x+8, y+h/2-8, w-16, "left")
  if focused then
    local t = love.timer.getTime()
    if math.floor(t*2)%2 == 0 then
      local tw = love.graphics.getFont():getWidth(disp)
      love.graphics.rectangle("fill", x+8+tw+2, y+h/2-10, 2, 16)
    end
  end
end

function ui.hitDice(x,y)
  local r = dice.getClickableRect()
  return x>=r.x and x<=r.x+r.w and y>=r.y and y<=r.y+r.h
end

function ui.pieceRadius()
  return 14
end

function ui.drawPiece(color, x, y, idx, piece, isTurn)
  local col = colorRGB[color] or {1,1,1}
  love.graphics.setColor(col[1], col[2], col[3], 1)
  love.graphics.circle("fill", x, y, ui.pieceRadius())
  love.graphics.setColor(0,0,0,0.3)
  love.graphics.circle("line", x, y, ui.pieceRadius())
  love.graphics.setColor(0,0,0,0.8)
  love.graphics.printf(tostring(idx), x-6, y-6, 12, "center")

  if isTurn then
    love.graphics.setColor(1,1,1,0.1)
    love.graphics.circle("fill", x, y, ui.pieceRadius()+6)
  end
end

-- ========== MENU ==========
local menuFields = {
  join_ip = "127.0.0.1",
  join_room = "",
  join_name = "Guest",
  local_players = "2",
  local_humans = "1",
}

function ui.drawMenu(game, net)
  local w, h = love.graphics.getDimensions()
  setFont(28*ui.scale)
  love.graphics.setColor(1,1,1)
  love.graphics.printf("Ludo", 0, 40, w, "center")

  setFont(16*ui.scale)
  local colW = 320
  local x = w/2 - colW/2
  local y = 120

  love.graphics.setColor(1,1,1,0.85)
  love.graphics.printf("Single Player / Local", x, y, colW, "center")
  y = y + 26
  love.graphics.setColor(1,1,1,0.9)
  love.graphics.print("Players (2-4)", x, y)
  textField("local_players", x+160, y-4, 60, 26, menuFields.local_players, false)
  y = y + 32
  love.graphics.print("Humans (1-4)", x, y)
  textField("local_humans", x+160, y-4, 60, 26, menuFields.local_humans, false)
  y = y + 36
  if button("start_local", x, y, colW, 36, "Start Local Game", true) then
    local total = tonumber(menuFields.local_players) or 2
    local humans = tonumber(menuFields.local_humans) or 1
    total = math.max(2, math.min(4, math.floor(total)))
    humans = math.max(1, math.min(total, math.floor(humans)))
    if ui.onStartLocalGame then
      ui.onStartLocalGame({humans=humans, total=total})
    end
  end

  y = y + 60
  love.graphics.setColor(1,1,1,0.85)
  love.graphics.printf("Online", x, y, colW, "center")
  y = y + 26
  if button("create_room", x, y, colW, 36, "Create Room (Host)", true) then
    if ui.onCreateRoom then ui.onCreateRoom(4) end
  end

  y = y + 50
  love.graphics.setColor(1,1,1,0.9)
  love.graphics.print("Host IP", x, y)
  textField("join_ip", x+160, y-4, 140, 26, menuFields.join_ip, false)
  y = y + 30
  love.graphics.print("Room Code", x, y)
  textField("join_room", x+160, y-4, 140, 26, menuFields.join_room, false)
  y = y + 30
  love.graphics.print("Your Name", x, y)
  textField("join_name", x+160, y-4, 140, 26, menuFields.join_name, false)
  y = y + 36
  if button("join_room_btn", x, y, colW, 36, "Join Room (Client)", true) then
    if ui.onJoinRoom then
      ui.onJoinRoom{ip=menuFields.join_ip, room=menuFields.join_room, name=menuFields.join_name}
    end
  end

  y = h - 40
  love.graphics.setColor(1,1,1,0.6)
  love.graphics.printf("ENet "..(hasEnet and "available" or "not found").." • Port 6789", 0, y, w, "center")
end

function ui.mousepressedMenu(x, y, button, game, net, setState)
  -- Buttons handled by draw via return values; nothing here
end

function ui.keypressed(key, onCommand)
  if ui.chatFocused then
    if key == "return" then
      local txt = ui.chatInput
      ui.chatInput = ""
      ui.chatFocused = false
      onCommand({type="chat", text=txt})
    elseif key == "backspace" then
      local byteoffset = utf8.offset(ui.chatInput, -1)
      if byteoffset then
        ui.chatInput = string.sub(ui.chatInput, 1, byteoffset - 1)
      end
    end
  else
    -- menu numeric fields editing is skipped for brevity
  end
end

function ui.textinput(t)
  if ui.chatFocused then
    ui.chatInput = ui.chatInput .. t
  end
end

function ui.clearChatInput() ui.chatInput = "" end
function ui.toggleChatFocus(v) ui.chatFocused = v end

-- ========== LOBBY ==========
function ui.drawLobby(game, net)
  local w, h = love.graphics.getDimensions()
  setFont(26*ui.scale)
  love.graphics.setColor(1,1,1)
  love.graphics.printf("Lobby", 0, 40, w, "center")

  setFont(16*ui.scale)
  love.graphics.printf("Room Code: "..(game.roomCode or "----"), 0, 80, w, "center")

  local y = 120
  for i=1,4 do
    local p = game.players[i]
    local label = p and (("[%d] %s %s"):format(i, p.name or "Player", p.isAI and "(AI)" or "")) or (("[slot %d] waiting..."):format(i))
    love.graphics.setColor(1,1,1, p and 1 or 0.5)
    love.graphics.printf(label, 0, y, w, "center")
    y = y + 26
  end

  local canStart = (game.isHost and #game.players >= 2)
  if button("lobby_start", w/2-120, h-120, 240, 40, game.isHost and "Start Match" or "Waiting for Host", canStart) then
    -- Host starts
    net.startMatchIfHost()
  end

  if button("lobby_back", 20, h-60, 160, 36, "Back", true) then
    net.leave()
    if love.handlers.state_update then
      love.handlers.state_update({state="menu"})
    end
  end
end

function ui.mousepressedLobby(x,y,button, game, net, onStarted)
  -- Start button handled in draw
end

-- ========== HUD ==========
local chatArea = {x=0,y=0,w=0,h=0}
local dicePos = {x=0,y=0}

function ui.drawHUD(ctx)
  local w, h = love.graphics.getDimensions()
  local game = ctx.game

  setFont(18*ui.scale)
  love.graphics.setColor(1,1,1)
  love.graphics.printf(("Turn: Player %d (%s)"):format(game.turn, (game.players[game.turn] and game.players[game.turn].name or "?")), 0, 8, w, "center")

  -- Dice area
  dicePos.x = w - 90
  dicePos.y = 20
  dice.draw(dicePos.x, dicePos.y)

  -- Chat window
  chatArea = {x = w-280, y = 100, w = 260, h = h-160}
  love.graphics.setColor(0,0,0,0.35)
  love.graphics.rectangle("fill", chatArea.x, chatArea.y, chatArea.w, chatArea.h, 6,6)
  love.graphics.setColor(1,1,1,0.7)
  love.graphics.rectangle("line", chatArea.x, chatArea.y, chatArea.w, chatArea.h, 6,6)

  local y = chatArea.y + 8
  for i = math.max(1, #game.chat-12), #game.chat do
    local m = game.chat[i]
    local line = ("%s: %s"):format(m.from or "?", m.text or "")
    love.graphics.setColor(1,1,1,0.95)
    love.graphics.printf(line, chatArea.x+6, y, chatArea.w-12, "left")
    y = y + 18
  end

  -- Chat input
  local ih = 28
  love.graphics.setColor(1,1,1)
  love.graphics.print("Enter to send chat", chatArea.x, chatArea.y + chatArea.h + 6)
  local focused = ui.chatFocused
  love.graphics.setColor(0.95,0.95,0.95,1)
  love.graphics.rectangle("fill", chatArea.x, chatArea.y + chatArea.h - ih, chatArea.w, ih, 6,6)
  love.graphics.setColor(0,0,0,0.2)
  love.graphics.rectangle("line", chatArea.x, chatArea.y + chatArea.h - ih, chatArea.w, ih, 6,6)
  love.graphics.setColor(0,0,0)
  love.graphics.printf(ui.chatInput, chatArea.x + 6, chatArea.y + chatArea.h - ih + ih/2 - 8, chatArea.w-12, "left")
  if focused and math.floor(love.timer.getTime()*2)%2 == 0 then
    local tw = love.graphics.getFont():getWidth(ui.chatInput)
    love.graphics.rectangle("fill", chatArea.x + 6 + tw + 2, chatArea.y + chatArea.h - ih + ih/2 - 10, 2, 18)
  end

  -- Legend / stats
  local legendX = 20
  local legendY = 60
  setFont(14*ui.scale)
  for i, p in ipairs(game.players) do
    local col = colorRGB[p.color] or {1,1,1}
    love.graphics.setColor(col)
    love.graphics.rectangle("fill", legendX, legendY + (i-1)*22, 16, 16, 3,3)
    love.graphics.setColor(1,1,1)
    local yardCount, homeCount, finished = 0, 0, p:finishedCount()
    for _, pc in ipairs(p.pieces) do
      if pc.yard then yardCount = yardCount + 1 end
      if pc.homeIndex ~= nil then homeCount = homeCount + 1 end
    end
    local txt = ("%s  yard:%d  home:%d  finished:%d %s"):format(p.name, yardCount, homeCount, finished, (i==game.turn) and "<" or "")
    love.graphics.print(txt, legendX+24, legendY+(i-1)*22)
  end
end

function ui.mousepressedHUD(x,y,button, game, net)
  -- Focus chat if clicking the input
  if x>=chatArea.x and x<=chatArea.x+chatArea.w and y>=chatArea.y+chatArea.h-28 and y<=chatArea.y+chatArea.h then
    ui.chatFocused = true
  else
    ui.chatFocused = false
  end
end

function ui.drawEnd(game, net)
  local w, h = love.graphics.getDimensions()
  setFont(28*ui.scale)
  local winName = (game.players[game.winnerSeat] and game.players[game.winnerSeat].name) or "?"
  love.graphics.setColor(1,1,1)
  love.graphics.printf("Winner: "..winName, 0, h/2-40, w, "center")

  if button("BackToMenu", w/2-120, h/2+20, 240, 44, "Back to Menu", true) then
    -- handled in main.mousepressed
  end
end

return ui