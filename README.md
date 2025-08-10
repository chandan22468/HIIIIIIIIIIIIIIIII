# Ludo (LÖVE 11.5 + lua-enet)

Authoritative online multiplayer Ludo with a robust single‑player fallback and basic AI. Runs on LÖVE 11.5. Networking uses lua‑enet when available; otherwise the game runs fully locally.

This project is intentionally simple and modular so you can study it, extend it, or ship it.

## File tree

```
project-root/
- conf.lua
- main.lua
- board.lua
- player.lua
- dice.lua
- network.lua
- ui.lua
- README.md
- assets/
  - board.png
  - red_piece.png
  - green_piece.png
  - blue_piece.png
  - yellow_piece.png
  - die1.png
  - die2.png
  - die3.png
  - die4.png
  - die5.png
  - die6.png
  - roll.wav
  - move.wav
  - knock.wav
  - win.wav
```

Binary assets are optional. If missing, the game draws placeholder visuals and plays no sounds.

## Requirements

- LÖVE 11.5: `love .`
- Optional for online multiplayer: lua‑enet (ENet bindings)

### Installing LÖVE

- macOS: Download from the LÖVE website and drag to Applications.
- Windows: Download installer and add `love.exe` to PATH.
- Linux: Use your distro packages or AppImage (11.5 recommended).

### Installing lua‑enet

lua‑enet is a LuaJIT/Lua binding for the ENet library.

- Windows:
  - Get a prebuilt `enet.dll` and the `enet.lua` binding (often packaged as `enet.dll` + `enet.pdb` etc.).
  - Place `enet.dll` next to `love.exe` or in your system PATH.
  - Place `enet.lua` in the project root or in `%APPDATA%\LOVE\love-ludo\`.
- macOS:
  - Install `enet` via Homebrew: `brew install enet`.
  - Ensure `enet` is visible to LÖVE’s LuaJIT (e.g., `libenet.dylib` in `/usr/local/lib`).
  - Put `enet.lua` in the project root.
- Linux:
  - Install system ENet: `sudo apt install libenet7` (or your distro equivalent).
  - Put `enet.so` and `enet.lua` where LuaJIT can find them (project root usually works).

If `require "enet"` fails at runtime, the game automatically falls back to local mode (single‑player or same‑machine local). You will still be able to play.

## Running

Open a terminal in the project root, then:

```
love .
```

Default window: 800×600, resizable, HiDPI‑aware.

## Modes

- Single Player / Local: 1–4 humans on the same machine, remaining seats are filled with AI (this sample treats seats beyond 1 as AI). 
- Online Host: Starts an authoritative server on port 6789 (if lua‑enet is present), generates a 6‑character room code, shows the lobby. Start when at least 2 players have joined.
- Online Client: Connect to a host by IP and room code. Client only sends intents; the host is authoritative.

If lua‑enet is missing, the host button starts a local‑only session and shows a note; joining by IP won’t work.

## Networking (authoritative)

- Transport: ENet (reliable for game events); port 6789.
- Room code: 6‑character alphanumeric. The server seeds RNG with `os.time()` and is authoritative for dice results and move validation.
- Clients send intents only:
  - `join_request {room, name}`
  - `roll_request {playerID}`
  - `move_request {playerID, pieceID, steps}` (pieceID `-1` means “pass/no‑move”)
  - `chat {from, text}`
- Server sends:
  - `join_response {ok, seat, room}` or `{ok=false, reason}`
  - `state_update {state, turn, dice={value}, players=[{...}], room, winner}`
  - `chat {from, text}`

All messages are JSON strings using `love.data.encode/decode("json")`.
Critical messages are sent reliably.

Disconnects: The host replaces a disconnected human with AI after a short timeout (in this example: immediate on disconnect). If the host dies, clients go back to the menu.

## Game rules

- Main path: 0..51 indices (52 squares).
- Player start offsets:
  - Red = 0
  - Green = 13
  - Blue = 26
  - Yellow = 39
- Safe squares (relative to Red 0): 1, 9, 14, 22, 27, 35, 40, 48.
- Leave yard only with a 6.
- Rolling a 6 grants an extra turn (after a valid move attempt).
- Knocking: landing on a square with exactly one opponent piece (not safe) sends it back to its yard.
- Blocks: two or more same‑color pieces on a square cannot be knocked; landing on an opponent block is invalid.
- Home entry: for color C, the piece enters home when it moves exactly to pass C’s entry index; this project’s board uses:
  - `entryIndex[color] = (startIndex[color] + 50) % 52`
  - The required number of steps to enter is `stepsToEnter = ((entryIndex - currentIndex + 52) % 52) + 1`.
- Home stretch has 6 squares; movement must be exact. Overshooting is invalid.
- Must move if possible; if no moves exist, the turn automatically passes.

Note: The board visuals are classic Ludo‑like (yards, center triangles, safe marks), and the piece path is a reliable 52‑step loop around the board. The positions of safe marks and entries match the logical indices defined above.

## Controls

- Click the die to request a roll (only on your turn).
- Click one of your highlighted pieces to request a move by the rolled count.
- Press Enter to focus chat; Enter again to send.
- Esc: clear chat focus / back / quit.

## Assets

The game runs without any files in `assets/`. If you add your own:

- `assets/board.png` (unused by default; board is drawn procedurally)
- `assets/red_piece.png`, `assets/green_piece.png`, `assets/blue_piece.png`, `assets/yellow_piece.png`
- `assets/die1.png` … `assets/die6.png`
- `assets/roll.wav`, `assets/move.wav`, `assets/knock.wav`, `assets/win.wav`

## Port forwarding (for hosting over the Internet)

If you host behind a router, forward UDP port 6789 to your machine’s LAN IP. Share your public IP and the room code with clients.

On Linux, you may need to allow UDP 6789 in your firewall:
```
sudo ufw allow 6789/udp
```

## Seed synchronization

- The host is authoritative for RNG. When a roll is requested, the host seeds its generator (`serverSeed + timestamp`), rolls, and broadcasts a snapshot including the rolled value. Clients display an animated die but never generate the value locally.
- This ensures all players see identical results without trusting clients.

## Troubleshooting

- “ENet not available”: Ensure `enet.lua` and its native library (`enet.dll`/`libenet.so`/`libenet.dylib`) are accessible. Otherwise, play Single Player or create a local game.
- “Cannot connect”: Verify host IP and that UDP 6789 is reachable. Try LAN first (e.g., `192.168.x.x`).
- Missing assets: It’s fine. The game draws placeholders.
- Performance: The static board is cached to a `Canvas`. If resized, it rebuilds automatically.

## Development notes

- Code is modular: `board`, `player`, `dice`, `network`, `ui`. The main loop manages game state and delegates to these modules.
- The UI is touch/mouse friendly with large click targets and responsive layout.

## Testing checklist

- Start Single Player (2 players): can roll, move, knock, and finish; 6 grants extra turn.
- Start Local 4 players: verify turn order and safe squares (no knocking on safe).
- Online Host + Client on LAN: client joins with room code; chat messages sync; host is authoritative.
- Disconnect a client: host replaces with AI; game continues.
- Resize window: board redraws; hit areas remain correct.
- No assets present: placeholders render; no crashes.
- Attempt invalid moves (e.g., overshoot home): move rejected; turn logic remains consistent.
