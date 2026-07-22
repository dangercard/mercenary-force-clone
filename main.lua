local SPEED = 50                        -- player speed, pixels per second
local SIZE = 16
local PLAY_TOP = 10                     -- default corridor top when a level has no terrain
local PLAY_BOTTOM = 169                 -- default corridor bottom

local TILE = 16                         -- terrain tile size (matches sprite grid)
local GRID_ROWS = math.ceil(180 / TILE) -- terrain rows covering the playfield

-- Terrain tiles: impassable scenery (trees, rocks, ...) dressing the walls.
-- Top-down view — the open lane is ground (GROUND_COLOR background) and the walls
-- are a *mix* of these tiles. They're interchangeable: all impassable, differing
-- only in sprite/color, so collision ignores which one a cell is. Add entries or
-- `spr = <cell>` freely. A `nil` grid cell = open ground (passable).
local TERRAIN_TILES = {
  { color = gfx.COLOR_DARK_GREEN },  -- tree
  { color = gfx.COLOR_GREEN },       -- bush
  { color = gfx.COLOR_DARK_GRAY },   -- rock
  { color = gfx.COLOR_LIGHT_GRAY },  -- boulder
}
local GROUND_COLOR = gfx.COLOR_BLACK -- open lane you fly over (top-down background)

local MEMBER_SIZE = 10
local FORM_TIME = 0.6      -- seconds to glide between formations
local FORM_LOCKOUT = 1.0   -- min seconds between formation switches (commitment)
local AUTO_FIRE = false    -- true: always firing; false: fire while BTN1 is held.
-- Either way, each member is gated by its own fire_rate.
local STARTING_MONEY = 500 -- wallet at the start of a new game
local COIN_VALUE = 10      -- money per coin dropped by a destroyed enemy
local COIN_RADIUS = 4      -- coin pickup circle radius
-- Columns in sprites.png = sheet width / sprite size. Only used to locate a cell
-- for sprite drawing; set this to match your sheet once you add one.
local SHEET_COLS = 16

-- Character types. To add one, drop a new entry here — nothing else changes.
--   color      : member rect color
--   hp         : hit points
--   fire_rate  : seconds between volleys
--   shots      : one volley = a list of projectiles, each with a velocity
--                (vx, vy in px/sec), size (w, h), and color. One entry = a
--                single stream; several entries = a spread / multi-direction.
--                Optional per-shot: ox/oy spawn offset from the member center,
--                and range (px) after which the bullet expires.
--   spr        : optional 1-based sprites.png cell; omit to draw a rect.
--   cost        : price to hire on the select screen.
local CHAR_TYPES = {

  cannon = {
    color = gfx.COLOR_BROWN,
    hp = 6,
    fire_rate = 1,
    cost = 40,
    shots = { { vx = 170, vy = 0, w = 9, h = 6, color = gfx.COLOR_ORANGE } },
  },
  twin = {
    color = gfx.COLOR_RED,
    hp = 12,
    fire_rate = 0.6,
    cost = 80,
    -- Two forward bullets from the member's top and bottom edges (oy = ±half of
    -- MEMBER_SIZE), each with a limited range.
    shots = {
      { vx = 200, vy = 0, oy = -5, w = 4, h = 2, color = gfx.COLOR_YELLOW, range = 100 },
      { vx = 200, vy = 0, oy = 5,  w = 4, h = 2, color = gfx.COLOR_YELLOW, range = 100 },
    },
  },
  vulcan = {
    color = gfx.COLOR_DARK_BLUE,
    hp = 10,
    fire_rate = 0.6,
    cost = 100,
    shots = { { vx = 260, vy = 0, w = 4, h = 2, color = gfx.COLOR_YELLOW, range = 110 } },
  },
  spread = {
    color = gfx.COLOR_ORANGE,
    hp = 9,
    fire_rate = 0.60,
    cost = 120,
    shots = {
      { vx = 210, vy = -80, w = 4, h = 4, color = gfx.COLOR_PEACH },
      -- { vx = 230, vy = 0,   w = 4, h = 4, color = gfx.COLOR_PEACH },
      { vx = 210, vy = 80,  w = 4, h = 4, color = gfx.COLOR_PEACH },
    },
  },
  column = {
    color = gfx.COLOR_WHITE,
    hp = 8,
    fire_rate = 0.3,
    cost = 70,
    -- Fires straight up and straight down (vertical bullets: tall, not wide).
    shots = {
      { vx = 0, vy = -240, w = 2, h = 4, color = gfx.COLOR_YELLOW },
      { vx = 0, vy = 240,  w = 2, h = 4, color = gfx.COLOR_YELLOW },
    },
  },

}

-- Roster: character types offered on the select screen, in display order.
local ROSTER = { "cannon", "twin", "vulcan", "spread", "column" }

-- Formation = per-member offset from the player anchor (State.x/y). BTN2 cycles
-- through these. Slot i uses offsets[i]; extra slots are ignored for small teams.
local FORMATIONS = {
  { name = "trail",  offsets = { { 0, 0 }, { -18, 0 }, { -36, 0 }, { -54, 0 } } },
  { name = "column", offsets = { { 0, -27 }, { 0, -9 }, { 0, 9 }, { 0, 27 } } },
  { name = "wedge",  offsets = { { 0, 0 }, { -18, -16 }, { -18, 16 }, { -36, 0 } } },
}

-- Move an enemy across the screen at `mag` px/s in its facing direction
-- (e.dir: -1 = leftward/normal, +1 = rightward/ambush), on top of the world
-- scroll so it crosses at the same screen speed regardless of scroll_speed.
local function advance(e, dt, mag)
  e.wx = e.wx + (e.dir * mag + State.level.scroll_speed) * dt
end

-- Movement patterns for spawned entities. Each gets the entity `e` and dt.
-- Horizontal motion goes through advance() so ambush enemies (dir = +1) mirror
-- it automatically; vertical motion is symmetric so it reads the same reversed.
local PATTERNS = {
  static = function() end, -- turrets/walls just ride the scroll
  straight = function(e, dt)
    advance(e, dt, 50)
  end,
  sine = function(e, dt)
    advance(e, dt, 40)
    e.t = e.t + dt
    e.y = e.y0 + math.sin(e.t * 3) * 30
  end,
  zigzag = function(e, dt)
    advance(e, dt, 45)
    e.t = e.t + dt
    local ph = (e.t % 1.2) / 1.2                  -- 0..1 sawtooth
    local tri = ph < 0.5 and ph * 2 or 2 - ph * 2 -- 0..1..0 triangle
    e.y = e.y0 + (tri * 2 - 1) * 34               -- sharp -34..34 weave
  end,
  dive = function(e, dt)
    advance(e, dt, 55)
    e.vy = (e.vy or 0) + 90 * dt -- accelerate downward
    e.y = e.y + e.vy * dt
  end,
  charge = function(e, dt)
    advance(e, dt, 100) -- fast straight rush
  end,
}

-- Entity type definitions: size + placeholder color. Add `spr = <cell>` (a
-- 1-based sprites.png index) to any entry to draw art instead of the rect.
-- `hp` is hit points; omit it to make the entity indestructible (walls still
-- stop bullets, they just don't take damage). `fire_rate` + `shots` (same shape
-- as CHAR_TYPES) make an enemy shoot. A shot with fixed `vx`/`vy` fires that
-- velocity (ambush enemies mirror it); a shot with `aim = true` instead points
-- at the squad using `speed` (px/s) with a random `spread` (radians of jitter).
local TYPES = {
  grunt  = { w = 12, h = 12, color = gfx.COLOR_RED, hp = 1 },
  wall   = { w = 20, h = 20, color = gfx.COLOR_LIGHT_GRAY },
  turret = {
    w = 16,
    h = 16,
    color = gfx.COLOR_ORANGE,
    hp = 3,
    fire_rate = 2.0,
    -- Aimed at the squad, ~20° of random spread — random but generally at you.
    shots = { { aim = true, speed = 110, spread = 0.35, w = 4, h = 4, color = gfx.COLOR_RED } },
  },
  gunner = {
    w = 12,
    h = 12,
    color = gfx.COLOR_INDIGO,
    hp = 2,
    fire_rate = 1.6,
    shots = { { vx = -130, vy = 0, w = 4, h = 4, color = gfx.COLOR_RED } },
  },
}

function _config()
  ---@type Usagi.Config
  return { name = "Mercenary_Force_Clone", game_id = "com.usagiengine.YOURGAMENAME" }
end

-- Interpolate the smooth keyframe corridor at world-x: returns (ceiling, floor).
-- Used only to bake the tilemap; gameplay reads the quantized grid via corridor_at.
local function terrain_at(profile, wx)
  local n = #profile
  if wx <= profile[1].x then return profile[1].ceiling, profile[1].floor end
  if wx >= profile[n].x then return profile[n].ceiling, profile[n].floor end
  for i = 1, n - 1 do
    local a, b = profile[i], profile[i + 1]
    if wx <= b.x then
      local t = (wx - a.x) / (b.x - a.x)
      return util.lerp(a.ceiling, b.ceiling, t), util.lerp(a.floor, b.floor, t)
    end
  end
  return profile[n].ceiling, profile[n].floor
end

-- Deterministic pseudo-random terrain tile for a cell, so both walls get a mix.
-- Placeholder scatter; swap for authored data or nicer noise later. The col*row
-- term breaks up linear striping. No RNG state, no bitwise (loveify-safe).
local function terrain_tile_at(col, row)
  local h = col * 73 + row * 179 + col * row * 13
  return h % #TERRAIN_TILES + 1
end

-- Bake the smooth keyframe corridor into a tile grid. Each column is filled with
-- a mix of terrain tiles from the top down to the (quantized) ceiling line and
-- from the floor line down. Per-column ceiling/floor pixels are cached so
-- collision reads the same blocky bounds the tiles are drawn at.
--   lvl.map[col][row] = tile id (nil = open ground); col/row are 0-based
--   lvl.ceil_px[col] / lvl.floor_px[col] = quantized corridor bounds in pixels
local function build_tilemap(lvl)
  local cols = math.ceil(lvl.length / TILE)
  lvl.cols = cols
  lvl.map = {}
  lvl.ceil_px = {}
  lvl.floor_px = {}
  for col = 0, cols - 1 do
    local worldx = col * TILE + TILE / 2
    local ceiling, floor = terrain_at(lvl.terrain, worldx)
    local ceil_rows = util.clamp(math.floor(ceiling / TILE + 0.5), 0, GRID_ROWS)
    local floor_row = util.clamp(math.floor(floor / TILE + 0.5), 0, GRID_ROWS)
    local column = {}
    for row = 0, ceil_rows - 1 do column[row] = terrain_tile_at(col, row) end
    for row = floor_row, GRID_ROWS - 1 do column[row] = terrain_tile_at(col, row) end
    lvl.map[col] = column
    lvl.ceil_px[col] = ceil_rows * TILE
    lvl.floor_px[col] = floor_row * TILE
  end
end

-- Tile-quantized corridor bounds at world-x: (ceiling_px, floor_px). Replaces
-- terrain_at everywhere in gameplay so collision matches the blocky tiles.
local function corridor_at(lvl, wx)
  local col = util.clamp(math.floor(wx / TILE), 0, lvl.cols - 1)
  return lvl.ceil_px[col], lvl.floor_px[col]
end

local function load_level(name)
  local lvl = usagi.read_json(name)
  -- Spawns must be sorted by x so the spawn cursor can just advance.
  table.sort(lvl.spawns, function(a, b) return a.x < b.x end)
  -- Terrain is optional; fall back to a flat corridor.
  lvl.terrain = lvl.terrain or { { x = 0, ceiling = PLAY_TOP, floor = PLAY_BOTTOM } }
  table.sort(lvl.terrain, function(a, b) return a.x < b.x end)
  lvl.length = lvl.length or 3000
  build_tilemap(lvl) -- bake keyframes → tile grid + quantized bounds
  return lvl
end

-- Draw art into a box. If `spr` (a 1-based sprites.png cell index) is given, draw
-- that cell scaled to (w, h) with its authored colors; otherwise fall back to a
-- solid rect in `color`. This is the single seam for sprites: a type with no
-- `spr` keeps its rect, so you can drop art in one type at a time.
local function draw_art(spr, x, y, w, h, color)
  if spr then
    local sz = usagi.SPRITE_SIZE
    local col = (spr - 1) % SHEET_COLS
    local row = math.floor((spr - 1) / SHEET_COLS)
    gfx.sspr_ex(col * sz, row * sz, sz, sz, x, y, w, h,
      false, false, 0, gfx.COLOR_TRUE_WHITE, 1.0)
  else
    gfx.rect_fill(x, y, w, h, color)
  end
end

-- Build a team from a loadout (list of CHAR_TYPES names, 1..4). Each member
-- copies its type's stats; initial cooldowns are staggered so they don't all
-- fire on the same frame. The type def is kept for its shots + color.
local function make_team(loadout)
  local team = {}
  for i, name in ipairs(loadout) do
    local def = assert(CHAR_TYPES[name], "unknown character type: " .. name)
    team[i] = {
      type = name,
      def = def,
      color = def.color,
      fire_rate = def.fire_rate,
      cooldown = (i - 1) * 0.12, -- stagger
      hp = def.hp,
      hurt_timer = 0,            -- i-frames after taking a hit
    }
  end
  return team
end

-- Interpolated formation offset for member i. During a switch we ease from the
-- previous formation's offset to the new one over FORM_TIME (smoothstep), so the
-- squad glides rather than snapping. Returns (dx, dy).
local function current_offset(i)
  local cur = FORMATIONS[State.formation].offsets[i]
  local prev = FORMATIONS[State.prev_formation].offsets[i]
  local t = State.form_t
  local e = t * t * (3 - 2 * t) -- smoothstep ease-in-out
  return util.lerp(prev[1], cur[1], e), util.lerp(prev[2], cur[2], e)
end

-- Screen position of member i: interpolated offset + anchor, with the vertical
-- spread scaled by State.squeeze (auto-compression through tight corridors).
local function member_pos(i)
  local dx, dy = current_offset(i)
  return State.x + dx, State.y + dy * State.squeeze
end

-- Velocity for an aimed enemy shot fired from (cx, cy): point at a random living
-- member's center, then rotate by a random angle up to `spread` radians — aim
-- that's random but always in the squad's general direction. Avoids atan2 (Lua
-- 5.5 vs LuaJIT differ) by normalizing the delta and rotating the vector. Falls
-- back to straight-left if the squad is empty.
local function aim_velocity(cx, cy, speed, spread)
  local n = #State.team
  if n == 0 then return -speed, 0 end
  local mx, my = member_pos(math.random(n))
  local dx, dy = (mx + MEMBER_SIZE / 2) - cx, (my + MEMBER_SIZE / 2) - cy
  local len = math.sqrt(dx * dx + dy * dy)
  if len == 0 then return -speed, 0 end
  local ux, uy = dx / len, dy / len
  local ang = (math.random() * 2 - 1) * (spread or 0.3)
  local ca, sa = math.cos(ang), math.sin(ang)
  return (ux * ca - uy * sa) * speed, (ux * sa + uy * ca) * speed
end

-- Leave the select screen and start the stage with the chosen squad. Resets all
-- gameplay fields on the shared State and flips the scene to "playing".
local function start_game(loadout)
  State.scene = "playing"
  State.x = 40
  State.y = 90         -- player anchor (leader position)
  State.scroll = 0     -- how far the world has scrolled
  State.next_spawn = 1 -- cursor into level.spawns
  State.entities = {}  -- live enemies/obstacles
  State.bullets = {}   -- player bullets (screen space)
  State.ebullets = {}  -- enemy bullets (screen space)
  State.coins = {}     -- money pickups dropped by dead enemies (world space)
  State.team = make_team(loadout)
  State.formation = 1
  State.prev_formation = 1 -- formation we're gliding from
  State.form_t = 1         -- transition progress 0..1 (1 = settled)
  State.form_cd = 0        -- switch lockout timer
  State.squeeze = 1        -- vertical-spread scale, shrinks to fit tight corridors
  State.level = load_level("level_1.json")
end

function _init()
  -- Start on the character-select screen; start_game() builds the stage once the
  -- player confirms their squad. F5 returns here.
  State = {
    scene = "select",
    cursor = 1,             -- highlighted roster entry
    chosen = {},            -- squad being built (list of type names, up to 4)
    money = STARTING_MONEY, -- persistent wallet; spending carries across stages
  }
end

local function spawn(s)
  local def = TYPES[s.type]
  local w = def.w
  local h = s.h or def.h -- walls can override height

  -- `ambush` (alias `behind`) makes the enemy enter from behind: it spawns just
  -- off the left edge and faces right (dir = +1), so its movement runs mirrored.
  local ambush = s.ambush or s.behind
  local dir = ambush and 1 or -1
  local wx = ambush and (State.scroll - w) or s.x

  -- Y placement. `anchor` mounts the entity on the terrain: "ceiling" hangs from
  -- the top wall, "floor" sits on the bottom wall. No anchor = use the literal y.
  -- Anchor to the *most protruding* wall point across the entity's width (min
  -- ceiling / max floor) rather than the center, so it sits flush on the tiles.
  local y = s.y or 0
  if s.anchor then
    local cL, fL = corridor_at(State.level, wx)
    local cR, fR = corridor_at(State.level, wx + w)
    if s.anchor == "ceiling" then
      y = math.min(cL, cR)
    else
      y = math.max(fL, fR) - h
    end
  end

  local e = {
    type = s.type,
    wx = wx, -- world x (where it lives on the scroll track)
    y = y,
    y0 = y,  -- baseline y for sine
    t = 0,
    w = w,
    h = h,
    dir = dir,               -- -1 = faces/moves left (normal), +1 = right (ambush)
    color = def.color,
    spr = def.spr,           -- nil until the type gets art; draw_art falls back to a rect
    hp = def.hp,             -- nil = indestructible
    hp_max = def.hp,         -- for the damage bar
    hit = 0,                 -- hit-flash timer
    move = PATTERNS[s.move or "static"],
    shots = def.shots,       -- nil = doesn't shoot
    fire_rate = def.fire_rate,
    fire_cd = def.fire_rate, -- first shot after one interval on screen
  }
  table.insert(State.entities, e)
end

local function update_play(dt)
  local lvl = State.level

  -- Advance the scroll.
  State.scroll = State.scroll + lvl.scroll_speed * dt

  -- Spawn everything the scroll line has reached (just past the right edge).
  while State.next_spawn <= #lvl.spawns
    and lvl.spawns[State.next_spawn].x <= State.scroll + 320 do
    spawn(lvl.spawns[State.next_spawn])
    State.next_spawn = State.next_spawn + 1
  end

  -- Player movement (longhand: preprocessor skips +=/-= on one-line ifs).
  if input.held(input.LEFT) then State.x = State.x - SPEED * dt end
  if input.held(input.RIGHT) then State.x = State.x + SPEED * dt end
  if input.held(input.UP) then State.y = State.y - SPEED * dt end
  if input.held(input.DOWN) then State.y = State.y + SPEED * dt end
  State.x = util.clamp(State.x, 0, 320 - SIZE)

  -- Advance the formation glide and the switch lockout.
  if State.form_t < 1 then
    State.form_t = math.min(1, State.form_t + dt / FORM_TIME)
  end
  if State.form_cd > 0 then
    State.form_cd = State.form_cd - dt
  end

  -- Switch formation with BTN2, but only once the lockout has expired and there
  -- are at least 2 members (a lone character has no formation to speak of).
  if input.pressed(input.BTN2) and State.form_cd <= 0 and #State.team > 1 then
    State.prev_formation = State.formation
    State.formation = State.formation % #FORMATIONS + 1
    State.form_t = 0
    State.form_cd = FORM_LOCKOUT
  end

  -- Current (possibly mid-glide) offset per member; used for corridor sampling,
  -- compression, and clamping so all three track the actual on-screen positions.
  local n = #State.team
  local mo = {}
  for i = 1, n do
    local dx, dy = current_offset(i)
    mo[i] = { dx, dy }
  end

  -- Sample the corridor at each member's own world-x (formations trail/spread
  -- the squad, so each faces a different gap). Track the tightest gap and the
  -- current vertical spread for auto-compression.
  local corr = {}
  local min_gap = math.huge
  local min_dy, max_dy = math.huge, -math.huge
  for i = 1, n do
    local mx = State.x + mo[i][1]
    local c1, f1 = corridor_at(lvl, mx + State.scroll)
    local c2, f2 = corridor_at(lvl, mx + MEMBER_SIZE + State.scroll)
    corr[i] = { ceiling = math.max(c1, c2), floor = math.min(f1, f2) }
    min_gap = math.min(min_gap, corr[i].floor - corr[i].ceiling)
    min_dy = math.min(min_dy, mo[i][2])
    max_dy = math.max(max_dy, mo[i][2])
  end

  -- Auto-compress: shrink the vertical spread to fit the tightest gap. Snap
  -- tighter instantly (never clip a wall on entry), ease back open smoothly.
  local spread = max_dy - min_dy
  local target = 1
  if spread > 0 then
    target = util.clamp((min_gap - MEMBER_SIZE) / spread, 0, 1)
  end
  if target < State.squeeze then
    State.squeeze = target
  else
    State.squeeze = util.approach(State.squeeze, target, dt * 3)
  end

  -- Clamp the anchor's Y so every member (at its squeezed offset) stays in the
  -- corridor. Terrain never damages — this just repositions the squad.
  local lo, hi = -math.huge, math.huge
  for i = 1, n do
    local dy = mo[i][2] * State.squeeze
    lo = math.max(lo, corr[i].ceiling - dy)
    hi = math.min(hi, corr[i].floor - MEMBER_SIZE - dy)
  end
  State.y = util.clamp(State.y, lo, hi)

  -- Team fire: hold BTN1 (or always, if AUTO_FIRE). Each member emits its type's
  -- volley from its own center, gated by its own fire_rate. Cooldown only ticks
  -- down while positive, so idling doesn't bank a burst on the next press.
  local firing = AUTO_FIRE or input.held(input.BTN1)
  for i, m in ipairs(State.team) do
    if m.cooldown > 0 then m.cooldown = m.cooldown - dt end
    if firing and m.cooldown <= 0 then
      m.cooldown = m.fire_rate
      local mx, my = member_pos(i)
      local cx, cy = mx + MEMBER_SIZE / 2, my + MEMBER_SIZE / 2
      for _, shot in ipairs(m.def.shots) do
        -- range (px) becomes a lifetime (s) = range / speed; nil = unlimited.
        local life
        if shot.range then
          local speed = math.sqrt(shot.vx * shot.vx + shot.vy * shot.vy)
          if speed > 0 then life = shot.range / speed end
        end
        table.insert(State.bullets, {
          x = cx + (shot.ox or 0) - shot.w / 2,
          y = cy + (shot.oy or 0) - shot.h / 2,
          vx = shot.vx,
          vy = shot.vy,
          w = shot.w,
          h = shot.h,
          color = shot.color,
          life = life,
        })
      end
    end
  end

  -- Move bullets by their velocity; tick down limited-range bullets.
  for _, b in ipairs(State.bullets) do
    b.x = b.x + b.vx * dt
    b.y = b.y + b.vy * dt
    if b.life then b.life = b.life - dt end
  end

  -- Update entity positions; tick down any hit-flash timer.
  for _, e in ipairs(State.entities) do
    e.move(e, dt)
    if e.hit > 0 then e.hit = e.hit - dt end
  end

  -- Enemy fire: shooters count down (only while on screen) and emit a volley of
  -- enemy bullets from their center. Bullet velocities come from the type's shots.
  for _, e in ipairs(State.entities) do
    if e.shots then
      local screen_x = e.wx - State.scroll
      if screen_x < 320 and screen_x + e.w > 0 then
        e.fire_cd = e.fire_cd - dt
        if e.fire_cd <= 0 then
          e.fire_cd = e.fire_rate
          local cx, cy = screen_x + e.w / 2, e.y + e.h / 2
          for _, shot in ipairs(e.shots) do
            local vx, vy
            if shot.aim then
              -- Aimed shot: point at the squad (with random spread), speed only.
              vx, vy = aim_velocity(cx, cy, shot.speed, shot.spread)
            else
              -- Fixed shot: authored velocity; ambush enemies fire mirrored.
              vx, vy = shot.vx * -e.dir, shot.vy
            end
            table.insert(State.ebullets, {
              x = cx - shot.w / 2,
              y = cy - shot.h / 2,
              vx = vx,
              vy = vy,
              w = shot.w,
              h = shot.h,
              color = shot.color,
            })
          end
        end
      end
    end
  end

  -- Move enemy bullets.
  for _, b in ipairs(State.ebullets) do
    b.x = b.x + b.vx * dt
    b.y = b.y + b.vy * dt
  end

  -- Bullet vs enemy: a bullet damages the enemy it overlaps and is consumed.
  -- Entities with no hp (walls) take no damage but still stop the bullet.
  for _, e in ipairs(State.entities) do
    local erect = { x = e.wx - State.scroll, y = e.y, w = e.w, h = e.h }
    for _, b in ipairs(State.bullets) do
      if not b.dead and util.rect_overlap(b, erect) then
        b.dead = true
        if e.hp then
          e.hp = e.hp - 1
          e.hit = 0.08 -- brief hit flash
          if e.hp <= 0 then
            e.dead = true
            -- Drop a coin at the enemy's center (world space).
            table.insert(State.coins,
              { wx = e.wx + e.w / 2, y = e.y + e.h / 2, value = COIN_VALUE })
            break -- entity gone; stop testing bullets against it
          end
        end
      end
    end
  end

  -- Cull bullets that hit something, expired (range), ran into terrain, or left
  -- the screen. Terrain stops them (they overlap the tile wall at their column).
  local live_bullets = {}
  for _, b in ipairs(State.bullets) do
    local expired = b.life and b.life <= 0
    local ceiling, floor = corridor_at(lvl, b.x + b.w / 2 + State.scroll)
    local in_terrain = b.y < ceiling or b.y + b.h > floor
    if not b.dead and not expired and not in_terrain
        and b.x + b.w > 0 and b.x < 320 and b.y + b.h > 0 and b.y < 180 then
      table.insert(live_bullets, b)
    end
  end
  State.bullets = live_bullets

  -- Cull entities that were destroyed or left the screen. Off the left for
  -- normal enemies; ambush enemies move right, so also cull past the right edge.
  local kept = {}
  for _, e in ipairs(State.entities) do
    local sx = e.wx - State.scroll
    if not e.dead and sx + e.w > 0 and sx < 360 then
      table.insert(kept, e)
    end
  end
  State.entities = kept

  -- Coins ride the scroll. A member overlapping one collects it (money += value);
  -- cull coins that scroll off the left edge.
  local live_coins = {}
  for _, c in ipairs(State.coins) do
    local cx = c.wx - State.scroll
    local circle = { x = cx, y = c.y, r = COIN_RADIUS }
    local collected = false
    for i = 1, #State.team do
      local mx, my = member_pos(i)
      if util.circ_rect_overlap(circle, { x = mx, y = my, w = MEMBER_SIZE, h = MEMBER_SIZE }) then
        State.money = State.money + c.value
        collected = true
        break
      end
    end
    if not collected and cx + COIN_RADIUS > 0 then
      table.insert(live_coins, c)
    end
  end
  State.coins = live_coins

  -- Member collision: enemy contact and enemy bullets both damage the member.
  -- I-frames stop a single hit from draining HP every frame. Dead members
  -- (hp <= 0) drop out and the squad closes ranks.
  local survivors = {}
  for i = 1, #State.team do
    local m = State.team[i]
    if m.hurt_timer > 0 then m.hurt_timer = m.hurt_timer - dt end
    local mx, my = member_pos(i)
    local mrect = { x = mx, y = my, w = MEMBER_SIZE, h = MEMBER_SIZE }
    for _, e in ipairs(State.entities) do
      local erect = { x = e.wx - State.scroll, y = e.y, w = e.w, h = e.h }
      if m.hurt_timer <= 0 and util.rect_overlap(mrect, erect) then
        m.hp = m.hp - 1
        m.hurt_timer = 0.6
        break
      end
    end
    for _, b in ipairs(State.ebullets) do
      if m.hurt_timer <= 0 and not b.dead and util.rect_overlap(mrect, b) then
        m.hp = m.hp - 1
        m.hurt_timer = 0.6
        b.dead = true
        break
      end
    end
    if m.hp > 0 then table.insert(survivors, m) end
  end
  State.team = survivors

  -- Cull enemy bullets that hit a member, ran into terrain, or left the screen.
  -- Terrain stops them (they overlap the tile wall at their column) but wall/
  -- obstacle entities don't — those aren't tested here, so bullets pass through.
  local live_ebullets = {}
  for _, b in ipairs(State.ebullets) do
    local ceiling, floor = corridor_at(lvl, b.x + b.w / 2 + State.scroll)
    local in_terrain = b.y < ceiling or b.y + b.h > floor
    if not b.dead and not in_terrain
        and b.x + b.w > 0 and b.x < 320 and b.y + b.h > 0 and b.y < 180 then
      table.insert(live_ebullets, b)
    end
  end
  State.ebullets = live_ebullets
end

local function draw_play(dt)
  gfx.clear(GROUND_COLOR) -- open lane = ground (top-down); terrain draws over it

  -- Terrain tilemap: stamp the visible columns' solid cells over the ground. Each
  -- tile draws via draw_art, so a TERRAIN_TILES entry with a `spr` shows art.
  local lvl = State.level
  local first_col = math.floor(State.scroll / TILE)
  local last_col = math.floor((State.scroll + 320) / TILE)
  for col = first_col, last_col do
    local column = lvl.map[col]
    if column then
      local dx = col * TILE - State.scroll
      for row = 0, GRID_ROWS - 1 do
        local id = column[row]
        if id then
          local t = TERRAIN_TILES[id]
          draw_art(t.spr, dx, row * TILE, TILE, TILE, t.color)
        end
      end
    end
  end

  -- Entities: world x minus scroll = screen x. Flash white briefly when hit.
  -- Destructible enemies show a small red HP bar above them once damaged.
  for _, e in ipairs(State.entities) do
    local ex = e.wx - State.scroll
    if e.hit > 0 then
      gfx.rect_fill(ex, e.y, e.w, e.h, gfx.COLOR_WHITE)
    else
      draw_art(e.spr, ex, e.y, e.w, e.h, e.color)
    end
    if e.hp and e.hp < e.hp_max then
      gfx.rect_fill(ex, e.y - 3, e.w, 1, gfx.COLOR_DARK_GRAY)
      gfx.rect_fill(ex, e.y - 3, e.w * (e.hp / e.hp_max), 1, gfx.COLOR_RED)
    end
  end

  -- Player bullets (per-shot size + color).
  for _, b in ipairs(State.bullets) do
    gfx.rect_fill(b.x, b.y, b.w, b.h, b.color)
  end

  -- Enemy bullets.
  for _, b in ipairs(State.ebullets) do
    gfx.rect_fill(b.x, b.y, b.w, b.h, b.color)
  end

  -- Coins (money pickups).
  for _, c in ipairs(State.coins) do
    gfx.circ_fill(c.wx - State.scroll, c.y, COIN_RADIUS, gfx.COLOR_YELLOW)
  end

  -- Team members. Blink white while in i-frames after a hit (a plain white box
  -- over the sprite/rect reads as a hit in both modes).
  for i, m in ipairs(State.team) do
    local mx, my = member_pos(i)
    if m.hurt_timer > 0 and util.flash(m.hurt_timer, 12) then
      gfx.rect_fill(mx, my, MEMBER_SIZE, MEMBER_SIZE, gfx.COLOR_WHITE)
    else
      draw_art(m.def.spr, mx, my, MEMBER_SIZE, MEMBER_SIZE, m.color)
    end
  end

  -- Prototype HUD: scroll progress, formation, squad size.
  gfx.text("scroll " .. math.floor(State.scroll), 4, 2, gfx.COLOR_WHITE)
  local form_ready = State.form_cd <= 0
  gfx.text("form: " .. FORMATIONS[State.formation].name .. (form_ready and "" or " *"),
    4, 12, form_ready and gfx.COLOR_WHITE or gfx.COLOR_DARK_GRAY)
  gfx.text("team: " .. #State.team, 4, 22, gfx.COLOR_WHITE)
  gfx.text("fire: " .. (AUTO_FIRE and "auto" or "hold BTN1"), 4, 32, gfx.COLOR_WHITE)
  gfx.text("$" .. State.money, 4, 42, gfx.COLOR_YELLOW)

  -- Floating team HUD along the bottom: each character's own HP (per-character,
  -- not pooled) — a color swatch for the member followed by its current HP.
  local hx = 4
  for _, m in ipairs(State.team) do
    gfx.rect_fill(hx, 166, 6, 6, m.color)
    gfx.text(tostring(m.hp), hx + 9, 166, gfx.COLOR_WHITE)
    hx = hx + 30
  end
end

-- CHARACTER SELECT ----------------------------------------------------------

local function update_select(dt)
  -- Move the cursor through the roster (wraps).
  if input.pressed(input.UP) then
    State.cursor = (State.cursor - 2) % #ROSTER + 1
  elseif input.pressed(input.DOWN) then
    State.cursor = State.cursor % #ROSTER + 1
  end

  -- BTN1 hires the highlighted type (up to 4, if affordable); BTN2 refunds the
  -- last pick. Money is spent on hire and returned on refund.
  if input.pressed(input.BTN1) and #State.chosen < 4 then
    local name = ROSTER[State.cursor]
    local cost = CHAR_TYPES[name].cost
    if State.money >= cost then
      State.money = State.money - cost
      table.insert(State.chosen, name)
    end
  elseif input.pressed(input.BTN2) and #State.chosen > 0 then
    local name = table.remove(State.chosen)
    State.money = State.money + CHAR_TYPES[name].cost
  end

  -- BTN3 starts the stage once at least one member is picked.
  if input.pressed(input.BTN3) and #State.chosen >= 1 then
    start_game(State.chosen)
  end
end

local function draw_select(dt)
  gfx.clear(gfx.COLOR_BLACK)
  gfx.text("SELECT YOUR SQUAD", 90, 14, gfx.COLOR_WHITE)
  gfx.text("$" .. State.money, 20, 26, gfx.COLOR_YELLOW)

  -- Roster list: color swatch + name + stats + cost, cursor highlights a row.
  -- Rows you can't afford are dimmed and show the cost in red.
  for i, name in ipairs(ROSTER) do
    local def = CHAR_TYPES[name]
    local y = 40 + (i - 1) * 16
    local affordable = State.money >= def.cost
    if i == State.cursor then
      gfx.rect_fill(20, y - 2, 180, 14, gfx.COLOR_DARK_GRAY)
    end
    gfx.rect_fill(24, y, 10, 10, def.color)
    local name_col = affordable and gfx.COLOR_WHITE or gfx.COLOR_DARK_GRAY
    gfx.text(name, 40, y + 1, name_col)
    gfx.text("hp " .. def.hp, 100, y + 1, gfx.COLOR_LIGHT_GRAY)
    gfx.text("$" .. def.cost, 150, y + 1, affordable and gfx.COLOR_YELLOW or gfx.COLOR_RED)
  end

  -- Chosen squad: four slots, filled right-to-left (first hire = rightmost, so
  -- it reads like the in-game trail formation with the leader out front).
  gfx.text("SQUAD", 224, 30, gfx.COLOR_WHITE)
  for slot = 1, 4 do
    local x = 224 + (4 - slot) * 22
    local picked = State.chosen[slot]
    if picked then
      gfx.rect_fill(x, 44, 16, 16, CHAR_TYPES[picked].color)
    else
      gfx.rect(x, 44, 16, 16, gfx.COLOR_DARK_GRAY)
    end
  end

  gfx.text("BTN1 hire   BTN2 refund", 20, 150, gfx.COLOR_LIGHT_GRAY)
  local can_start = #State.chosen >= 1
  gfx.text("BTN3 start", 20, 162, can_start and gfx.COLOR_GREEN or gfx.COLOR_DARK_GRAY)
end

-- SCENE DISPATCH ------------------------------------------------------------

function _update(dt)
  if State.scene == "select" then
    update_select(dt)
  else
    update_play(dt)
  end
end

function _draw(dt)
  if State.scene == "select" then
    draw_select(dt)
  else
    draw_play(dt)
  end
end
