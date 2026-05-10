-- WorldConfig.lua
-- World constants and configuration for GrowRoblox
-- 2D tile-based world (Growtopia-style)

local WorldConfig = {}

-- World dimensions
WorldConfig.WORLD_WIDTH = 100   -- X axis (columns)
WorldConfig.WORLD_HEIGHT = 60   -- Y axis (rows) — Y=0 is top, Y=59 is bottom

-- Tile visual size in PIXELS (used by 2D GUI renderer / WorldRenderer)
WorldConfig.TILE_SIZE = 32

-- Tile size in STUDS (used by 3D Roblox world: DropService, PlayerManager, CameraController, InputController)
-- Every Part in the world is 4x4x4 studs. Character position to tile conversion uses this.
WorldConfig.TILE_SIZE_STUDS = 4

-- Visible viewport (how many tiles visible at once in 2D renderer)
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

-- World layers (0-indexed Y, Y=0 is top)
WorldConfig.LAYER_SKY_START = 0
WorldConfig.LAYER_SKY_END = 4
WorldConfig.LAYER_SURFACE_Y = 5
WorldConfig.LAYER_UNDERGROUND_START = 6
WorldConfig.LAYER_UNDERGROUND_END = 34
WorldConfig.LAYER_DEEP_START = 35
WorldConfig.LAYER_DEEP_END = 49
WorldConfig.LAYER_LAVA_START = 50
WorldConfig.LAYER_LAVA_END = 53
WorldConfig.LAYER_BEDROCK_START = 54
WorldConfig.LAYER_BEDROCK_END = 59

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

-- Helper functions
function WorldConfig.IsValidPosition(x: number, y: number): boolean
	return x >= 0 and x < WorldConfig.WORLD_WIDTH
		and y >= 0 and y < WorldConfig.WORLD_HEIGHT
end

function WorldConfig.TileIndex(x: number, y: number): number
	return x + y * WorldConfig.WORLD_WIDTH
end

function WorldConfig.IndexToTile(index: number): (number, number)
	local x = index % WorldConfig.WORLD_WIDTH
	local y = math.floor(index / WorldConfig.WORLD_WIDTH)
	return x, y
end

--[[
	Get the tile coordinates of a player's current position.
	Uses TILE_SIZE_STUDS (4) for 3D world position conversion.
	Y-axis is inverted: Roblox Y increases upward, tile Y increases downward.

	@param player: Player
	@return number?, number? — tileX, tileY or nil if character not found
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
	Convert tile coordinates to Roblox world position (3D).
	Used by DropService, PlayerManager, CameraController.

	@param tileX: number
	@param tileY: number
	@return Vector3
]]
function WorldConfig.TileToWorldPosition(tileX: number, tileY: number): Vector3
	return Vector3.new(
		tileX * WorldConfig.TILE_SIZE_STUDS,
		-tileY * WorldConfig.TILE_SIZE_STUDS,
		0
	)
end

--[[
	Convert Roblox world position to tile coordinates.
	Used by InputController, DropService.

	@param worldPos: Vector3
	@return number, number — tileX, tileY
]]
function WorldConfig.WorldPositionToTile(worldPos: Vector3): (number, number)
	local tileX = math.floor(worldPos.X / WorldConfig.TILE_SIZE_STUDS + 0.5)
	local tileY = math.floor(-worldPos.Y / WorldConfig.TILE_SIZE_STUDS + 0.5)
	return tileX, tileY
end

--[[
	Calculate Chebyshev distance between two tile positions.
	Used for reach checks (max of X and Y delta).

	@param x1: number
	@param y1: number
	@param x2: number
	@param y2: number
	@return number
]]
function WorldConfig.GetTileDistance(x1: number, y1: number, x2: number, y2: number): number
	return math.max(math.abs(x2 - x1), math.abs(y2 - y1))
end

return WorldConfig