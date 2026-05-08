-- WorldConfig.lua
-- World constants and configuration for GrowRoblox
-- 2D tile-based world (Growtopia-style)

local WorldConfig = {}

-- World dimensions
WorldConfig.WORLD_WIDTH = 100   -- X axis (columns)
WorldConfig.WORLD_HEIGHT = 60   -- Y axis (rows) — Y=1 is top, Y=60 is bottom

-- Tile visual size on screen (pixels)
WorldConfig.TILE_SIZE = 32

-- Visible viewport (how much visible at once)
WorldConfig.VIEWPORT_TILES_X = 20
WorldConfig.VIEWPORT_TILES_Y = 14

-- Gameplay
WorldConfig.MAX_INVENTORY_SLOTS = 32
WorldConfig.HOTBAR_SLOTS = 9
WorldConfig.MAX_STACK_SIZE = 200
WorldConfig.DEFAULT_GEMS = 0
WorldConfig.PLAYER_REACH = 4    -- tiles
WorldConfig.DEFAULT_GROWTH_TIME = 60  -- seconds for common items

-- Player physics (2D)
WorldConfig.GRAVITY = 50        -- pixels/s²
WorldConfig.JUMP_VELOCITY = -400 -- pixels/s (negative = up)
WorldConfig.MOVE_SPEED = 200    -- pixels/s
WorldConfig.PLAYER_WIDTH = 20   -- pixels
WorldConfig.PLAYER_HEIGHT = 28  -- pixels

-- World layers (Y=1 is top)
WorldConfig.LAYER_SKY_START = 1
WorldConfig.LAYER_SKY_END = 5
WorldConfig.LAYER_SURFACE_Y = 6
WorldConfig.LAYER_UNDERGROUND_START = 7
WorldConfig.LAYER_UNDERGROUND_END = 35
WorldConfig.LAYER_DEEP_START = 36
WorldConfig.LAYER_DEEP_END = 50
WorldConfig.LAYER_LAVA_START = 51
WorldConfig.LAYER_LAVA_END = 54
WorldConfig.LAYER_BEDROCK_START = 55
WorldConfig.LAYER_BEDROCK_END = 60

-- Item types (from Growtopia source)
WorldConfig.ItemTypes = {
	FIST = 0,
	WRENCH = 1,
	DOOR = 2,
	LOCK = 3,
	GEMS = 4,
	DEADLY = 6,
	CONSUMABLE = 8,
	SIGN = 10,
	BOOMBOX = 12,
	PLATFORM = 14,
	BEDROCK = 15,
	LAVA = 16,
	SOLID = 17,
	BACKGROUND = 18,
	SEED = 19,
	CLOTHES = 20,
	PORTAL = 26,
	ICE = 29,
}

-- Make ItemTypes accessible via string and number
WorldConfig.GetItemTypeName = function(typeId: number): string?
	for name, id in pairs(WorldConfig.ItemTypes) do
		if id == typeId then
			return name
		end
	end
	return nil
end

-- World-space tile size in studs (used for character-position-to-tile-coordinate conversion)
-- Each tile occupies a 4×4 stud area in the 3D world
WorldConfig.TILE_SIZE_STUDS = 4

-- Helper functions
function WorldConfig.IsValidPosition(x: number, y: number): boolean
	return x >= 0 and x < WorldConfig.WORLD_WIDTH
		and y >= 0 and y < WorldConfig.WORLD_HEIGHT
end

function WorldConfig.TileIndex(x: number, y: number): number
	-- Flat array index: x + y * width
	return x + y * WorldConfig.WORLD_WIDTH
end

function WorldConfig.IndexToTile(index: number): (number, number)
	local x = index % WorldConfig.WORLD_WIDTH
	local y = math.floor(index / WorldConfig.WORLD_WIDTH)
	return x, y
end

--[[
	Get the tile coordinates of a player's current position.
	Calculated from the character's HumanoidRootPart world position.
	Uses Chebyshev rounding: math.floor(pos / TILE_SIZE + 0.5)

	Y-axis formula: math.floor(-pos.Y / TILE_SIZE_STUDS + 0.5)
	- Roblox Y increases upward, tile Y increases downward (Y=0 is top)
	- A player at world Y=-16 → tileY = round(16/4) = 4

	X-axis formula: math.floor(pos.X / TILE_SIZE_STUDS + 0.5)
	- Tile 0 starts at world position 0

	@param player: Player — the player
	@return number?, number? — tileX, tileY, or nil if character/HumanoidRootPart not found
]]
function WorldConfig.GetPlayerTilePosition(player: Player): (number?, number?)
	local character = player.Character
	if not character then
		return nil, nil
	end

	local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoidRootPart then
		return nil, nil
	end

	local tileX = math.floor(humanoidRootPart.Position.X / WorldConfig.TILE_SIZE_STUDS + 0.5)
	local tileY = math.floor(-humanoidRootPart.Position.Y / WorldConfig.TILE_SIZE_STUDS + 0.5)

	return tileX, tileY
end

--[[
	Calculate Chebyshev distance (max of X and Y delta) between two tile positions.

	@param x1: number — first tile X
	@param y1: number — first tile Y
	@param x2: number — second tile X
	@param y2: number — second tile Y
	@return number — Chebyshev distance in tiles
]]
function WorldConfig.GetTileDistance(x1: number, y1: number, x2: number, y2: number): number
	return math.max(math.abs(x2 - x1), math.abs(y2 - y1))
end

return WorldConfig
