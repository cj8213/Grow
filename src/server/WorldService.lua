-- WorldService.lua
-- Server-side world generation, saving, and loading
-- Produces a 100×60 tile grid with correct layer layout, randomized terrain, and Main Door placement
-- Uses 2D tile system (Growtopia-style, not 3D voxels)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local Shared = require(ReplicatedStorage.Shared)
local WorldConfig = require(ReplicatedStorage.Shared.WorldConfig)
local ItemDatabase = require(ReplicatedStorage.Shared.ItemDatabase)

local WorldService = {}

-- Export world dimensions for other modules
WorldService.WORLD_WIDTH = WorldConfig.WORLD_WIDTH
WorldService.WORLD_HEIGHT = WorldConfig.WORLD_HEIGHT

-- Cache of loaded worlds: worldName -> worldData
local worldCache = {}

-- Set of special world names (e.g. "START") that are never unloaded, never saved sparse
local SPECIAL_WORLDS: { [string]: boolean } = {
	["START"] = true,
}

--[[
	Create a new tile structure for the world grid
	Tile format: { fg = itemId, bg = itemId, hp = number, owner = nil, treeData = nil }
	Stored as a flat array of 6000 tiles indexed by x + y * WORLD_WIDTH
]]
local function createEmptyTile()
	return {
		fg = 0,         -- foreground block (0 = air)
		bg = 0,         -- background block (0 = air)
		hp = 0,         -- current HP (0 = no block)
		owner = nil,    -- lock owner userId
		treeData = nil, -- { seedId, plantedAt, growthTime } if planted
		fgExtra = nil,  -- optional extra data for fg blocks (e.g. { doorDestination = "WORLDNAME" })
	}
end

--[[
	Generate a new world from scratch with procedural terrain
	Layer layout (Y=1 is top of grid, Y=60 is bottom):
	Y 1-5:   Sky (empty)
	Y 6:     Surface (Dirt fg, empty bg) — grass top
	Y 7-35:  Underground (Dirt fg, Cave Background bg)
	Y 36-50: Deep (Rock fg, Cave Background bg)
	Y 51-54: Lava zone (Lava bg, mixed Rock/Dirt fg)
	Y 55-60: Bedrock (indestructible)
]]
function WorldService.GenerateWorld(worldName: string, seed: number?): table
	local rng = Random.new(seed or os.time())
	
	-- Create flat array of 6000 tiles (100 * 60)
	local tiles = {}
	for i = 1, WorldConfig.WORLD_WIDTH * WorldConfig.WORLD_HEIGHT do
		tiles[i] = createEmptyTile()
	end

	-- Helper to get/set a tile
	local function getTile(x, y)
		if x < 0 or x >= WorldConfig.WORLD_WIDTH or y < 0 or y >= WorldConfig.WORLD_HEIGHT then
			return nil
		end
		return tiles[x + y * WorldConfig.WORLD_WIDTH + 1]
	end

	local function setTile(x, y, fg, bg, hp)
		local tile = getTile(x, y)
		if not tile then return end
		tile.fg = fg
		tile.bg = bg
		tile.hp = hp
	end

	-- Y is inverted: Y=0 is the TOP of the world visually (row 1 from spec)
	-- But internally we use 0-indexed Y where 0 = top, 59 = bottom
	-- This means Y=55-59 is Bedrock (bottom 6 rows)

	-- Layer constants (0-indexed)
	local LAYER_SKY_END = 4           -- Y 0-4: Sky (5 rows)
	local LAYER_SURFACE_Y = 5          -- Y 5: Surface (1 row)
	local LAYER_UNDERGROUND_START = 6  -- Y 6-34: Underground (29 rows)
	local LAYER_UNDERGROUND_END = 34
	local LAYER_DEEP_START = 35        -- Y 35-49: Deep (15 rows)
	local LAYER_DEEP_END = 49
	local LAYER_LAVA_START = 50        -- Y 50-53: Lava zone (4 rows)
	local LAYER_LAVA_END = 53
	local LAYER_BEDROCK_START = 54     -- Y 54-59: Bedrock (6 rows)
	local LAYER_BEDROCK_END = 59

	-- Build layers with FLAT surface (no height variation)
	-- All tiles are filled solid from bedrock up to surface, no gaps
	for x = 0, WorldConfig.WORLD_WIDTH - 1 do
		for y = 0, WorldConfig.WORLD_HEIGHT - 1 do
			if y >= LAYER_BEDROCK_START and y <= LAYER_BEDROCK_END then
				-- Bedrock layer (Y 54-59, bottom 6 rows)
				local itemId = 5  -- Bedrock
				setTile(x, y, itemId, 0, 99999)

			elseif y >= LAYER_LAVA_START and y <= LAYER_LAVA_END then
				-- Lava zone (Y 50-53, 4 rows)
				-- Background: Lava
				-- Foreground: mix of Rock and Dirt, NO empty spaces
				local fgBlock = 2  -- Default: Rock
				if rng:NextNumber() < 0.4 then
					fgBlock = 1  -- Dirt
				end
				setTile(x, y, fgBlock, 4, ItemDatabase.GetItem(fgBlock).hp)

			elseif y >= LAYER_DEEP_START and y <= LAYER_DEEP_END then
				-- Deep layer (Y 35-49, 15 rows)
				-- Foreground: Rock
				-- Background: Cave Background
				setTile(x, y, 2, 3, ItemDatabase.GetItem(2).hp)

			elseif y >= LAYER_UNDERGROUND_START and y <= LAYER_UNDERGROUND_END then
				-- Underground layer (Y 6-34, 29 rows)
				-- Foreground: Dirt
				-- Background: Cave Background
				setTile(x, y, 1, 3, ItemDatabase.GetItem(1).hp)

				-- Randomly scatter Rock deposits in Dirt layers
				if rng:NextNumber() < 0.08 then
					setTile(x, y, 2, 3, ItemDatabase.GetItem(2).hp)
				end

			elseif y == LAYER_SURFACE_Y then
				-- Surface row (Y = 5, flat across entire width)
				-- Foreground: Dirt (top layer)
				-- Background: empty
				setTile(x, y, 1, 0, ItemDatabase.GetItem(1).hp)

			elseif y < LAYER_SURFACE_Y then
				-- Sky (above surface, Y 0-4)
				-- Everything is air
				setTile(x, y, 0, 0, 0)

			end
		end
	end

	-- Place Main Door on the surface (always accessible, indestructible)
	local doorX = math.floor(WorldConfig.WORLD_WIDTH / 2)
	local doorY = LAYER_SURFACE_Y
	-- Place the Main Door as an indestructible foreground block
	-- Also place a Bedrock tile directly under the Main Door
	setTile(doorX, doorY, 6, 0, 99999)         -- Main Door foreground (indestructible)
	if doorY + 1 < WorldConfig.WORLD_HEIGHT then
		setTile(doorX, doorY + 1, 5, 0, 99999) -- Bedrock directly under door
	end

	-- Assemble world data structure
	local worldData = {
		name = worldName,
		tiles = tiles,
		lockOwner = nil,
		admins = {},
		createdAt = os.time(),
		updatedAt = os.time(),
		generationSeed = seed or os.time(),
	}

	-- Log world stats for verification
	local stats = WorldService.GetWorldStats(worldData)
	print(`[WorldService] Generated world "{worldName}"`)
	print(`[WorldService]   Tiles: {stats.totalTiles} ({stats.width}x{stats.height})`)
	print(`[WorldService]   Bedrock: {stats.bedrockCount}, Surface: {stats.surfaceCount}`)
	print(`[WorldService]   Underground: {stats.undergroundCount}, Deep: {stats.deepCount}`)
	print(`[WorldService]   Lava zone: {stats.lavaZoneCount}, Sky: {stats.skyCount}`)
	print(`[WorldService]   Main Door at X={doorX}, Y={doorY}`)
	print(`[WorldService]   Surface is flat at Y={LAYER_SURFACE_Y}`)

	return worldData
end

--[[
	Get statistics about a generated world for verification
]]
function WorldService.GetWorldStats(worldData: table): table
	local tiles = worldData.tiles
	local bedrockCount = 0
	local surfaceCount = 0
	local undergroundCount = 0
	local deepCount = 0
	local lavaZoneCount = 0
	local skyCount = 0
	local minSurfaceY = 99
	local maxSurfaceY = 0

	for y = 0, WorldConfig.WORLD_HEIGHT - 1 do
		local hasSurface = false
		for x = 0, WorldConfig.WORLD_WIDTH - 1 do
			local tile = tiles[x + y * WorldConfig.WORLD_WIDTH + 1]
			if tile then
				if tile.fg > 0 then
					if y >= 54 then
						bedrockCount += 1
					elseif y >= 50 then
						lavaZoneCount += 1
					elseif y >= 35 then
						deepCount += 1
					elseif y >= 6 and y <= 34 then
						undergroundCount += 1
					elseif tile.fg == 1 or tile.fg == 6 then
						surfaceCount += 1
						hasSurface = true
						if y < minSurfaceY then minSurfaceY = y end
						if y > maxSurfaceY then maxSurfaceY = y end
					end
				end
			end
		end
		if not hasSurface then
			skyCount += 1
		end
	end

	return {
		width = WorldConfig.WORLD_WIDTH,
		height = WorldConfig.WORLD_HEIGHT,
		totalTiles = #tiles,
		bedrockCount = bedrockCount,
		surfaceCount = surfaceCount,
		undergroundCount = undergroundCount,
		deepCount = deepCount,
		lavaZoneCount = lavaZoneCount,
		skyCount = skyCount,
		minSurfaceY = minSurfaceY,
		maxSurfaceY = maxSurfaceY,
	}
end

--[[
	Apply saved sparse tile data onto a freshly generated world.
	Used by LoadWorld when loaded tile data exists in DataStore.
	Merges saved tiles (which differ from defaults) onto the generated base.

	@param worldData: table — the freshly generated world data
	@param savedTiles: { { i: number, fg: number?, bg: number?, treeData: table? } } — sparse tile array
	@return table — the merged worldData (tiles updated in-place)
]]
function WorldService.LoadSavedWorld(worldData: table, savedTiles: { { i: number, fg: number?, bg: number?, hp: number?, treeData: table? } }): table
	if not worldData or not worldData.tiles or not savedTiles then
		return worldData
	end

	local tiles = worldData.tiles
	for _, entry in ipairs(savedTiles) do
		local i = entry.i
		if i and i >= 1 and i <= #tiles then
			local tile = tiles[i]
			-- Always apply fg, bg, and hp from saved entry (including 0 for broken/empty tiles)
			tile.fg = entry.fg
			tile.bg = entry.bg
			tile.hp = entry.hp
			if entry.treeData ~= nil then tile.treeData = entry.treeData end
		end
	end

	print(`[WorldService] Applied {#savedTiles} saved tiles to world "{worldData.name}"`)
	return worldData
end

--[[
	Load or create a world by name.
	First checks DataStore (via DataService) for saved data.
	If saved data exists, generates a fresh world and merges saved tiles onto it.
	Otherwise, generates a new world from scratch.

	@param worldName: string
	@param loadFromDataStore: boolean — if true, attempt to load saved data (default: true)
	@return table
]]
function WorldService.LoadWorld(worldName: string): table
	-- Normalize world name (uppercase, alphanumeric + underscore)
	local normalized = string.upper(string.gsub(worldName, "[^%w_]", ""))

	if #normalized == 0 then
		normalized = "MAIN"
	end
	if #normalized > 20 then
		normalized = string.sub(normalized, 1, 20)
	end

	-- Check cache first
	if worldCache[normalized] then
		print(`[WorldService] Loaded "{normalized}" from cache`)
		return worldCache[normalized]
	end

	-- Try to load from DataStore via DataService
	local savedWorldData = nil
	local DataService = require(script.Parent.DataService)
	if DataService then
		savedWorldData = DataService.LoadWorldData(normalized)
	end

	-- Always generate a base world (provides terrain, door, etc.)
	local worldData = WorldService.GenerateWorld(normalized, #normalized)

	-- If saved data exists, merge it onto the generated world
	if savedWorldData and savedWorldData.tiles then
		-- Restore metadata from saved data
		if savedWorldData.lockOwner ~= nil then worldData.lockOwner = savedWorldData.lockOwner end
		if savedWorldData.admins ~= nil then worldData.admins = savedWorldData.admins end
		if savedWorldData.createdAt ~= nil then worldData.createdAt = savedWorldData.createdAt end
		if savedWorldData.drops ~= nil then worldData.drops = savedWorldData.drops end
		-- Restore dynamic lock system data
		if savedWorldData.lockClaims ~= nil then worldData.lockClaims = savedWorldData.lockClaims end
		if savedWorldData.lockRegistry ~= nil then worldData.lockRegistry = savedWorldData.lockRegistry end
		if savedWorldData.nextLockId ~= nil then worldData.nextLockId = savedWorldData.nextLockId end

		WorldService.LoadSavedWorld(worldData, savedWorldData.tiles)
		local dropCount = if worldData.drops then #worldData.drops else 0
		print(`[WorldService] Loaded "{normalized}" from DataStore ({#savedWorldData.tiles} saved tiles, {dropCount} saved drops, {if worldData.lockRegistry then "locks" else "no locks"})`)
	else
		print(`[WorldService] Generated new world "{normalized}"`)
	end

	-- Cache the world
	worldCache[normalized] = worldData

	-- Respawn any persisted drops (survives server restarts)
	local DropService = require(script.Parent.DropService)
	if DropService then
		DropService.LoadSavedDrops(normalized, worldData)
	end

	local dropCount = worldData.drops and #worldData.drops or 0
	print(`[WorldService] Loaded world "{normalized}" with {dropCount} drops from DataStore`)

	-- Register with ProfileStore for auto-save tracking
	local ProfileStore = require(script.Parent.ProfileStore)
	if ProfileStore then
		ProfileStore.RegisterWorld(normalized, worldData)
	end

	return worldData
end

--[[
	Save a world's tiles to DataStore
]]
function WorldService.SaveWorld(worldName: string): boolean
	local normalized = string.upper(worldName)
	local worldData = worldCache[normalized]
	if not worldData then
		warn(`[WorldService] Cannot save "{worldName}": not in cache`)
		return false
	end

	worldData.updatedAt = os.time()

	-- Save to DataStore via DataService
	local DataService = require(script.Parent.DataService)
	if DataService then
		local success = DataService.SaveWorldData(normalized, worldData)
		if success then
			print(`[WorldService] Saved world "{normalized}" to DataStore`)
		else
			warn(`[WorldService] Failed to save world "{normalized}" to DataStore`)
		end
		return success
	end

	return false
end

--[[
	Save all loaded worlds
]]
function WorldService.SaveAll()
	for name, _ in pairs(worldCache) do
		WorldService.SaveWorld(name)
	end
	print("[WorldService] All worlds saved")
end

--[[
	Get all cached world data tables.
	Used by SeedService growth loop to iterate over all worlds.
	@return { [string]: table } — map of worldName -> worldData
]]
function WorldService.GetAllWorlds(): { [string]: table }
	return worldCache
end

--[[
	Get a cached world by name. Returns nil if the world is not loaded.
	Used by DropService to look up worldData for server-side pickup handling.

	@param worldName: string — normalized world name
	@return table?
]]
function WorldService.GetCachedWorld(worldName: string): table?
	return worldCache[string.upper(worldName)]
end

--[[
	Get a tile from a loaded world
]]
function WorldService.GetTile(worldName: string, x: number, y: number): table?
	local worldData = worldCache[string.upper(worldName)]
	if not worldData then return nil end
	if x < 0 or x >= WorldConfig.WORLD_WIDTH or y < 0 or y >= WorldConfig.WORLD_HEIGHT then
		return nil
	end
	return worldData.tiles[x + y * WorldConfig.WORLD_WIDTH + 1]
end

--[[
	Update a tile and broadcast to players in the world
]]
function WorldService.UpdateTile(worldName: string, x: number, y: number, fg: number?, bg: number?, hp: number?)
	local worldData = worldCache[string.upper(worldName)]
	if not worldData then return false end

	local tile = WorldService.GetTile(worldName, x, y)
	if not tile then return false end

	if fg ~= nil then tile.fg = fg end
	if bg ~= nil then tile.bg = bg end
	if hp ~= nil then tile.hp = hp end

	worldData.updatedAt = os.time()

	-- TODO: Broadcast TileUpdated to all players in this world
	return true
end

--[[
	Check if a world is locked and who owns it
]]
function WorldService.GetLockInfo(worldName: string): (boolean, number?)
	local worldData = worldCache[string.upper(worldName)]
	if not worldData then return false, nil end
	return worldData.lockOwner ~= nil, worldData.lockOwner
end

--[[
	Set or remove a world lock
]]
function WorldService.SetWorldLock(worldName: string, userId: number?, admins: { number }?)
	local worldData = worldCache[string.upper(worldName)]
	if not worldData then return false end

	worldData.lockOwner = userId
	worldData.admins = admins or {}
	worldData.updatedAt = os.time()

	print(`[WorldService] World "{worldName}" lock set to userId={userId}`)
	return true
end

--[[
	===== TASK #8 ADDITIONS =====
	GetOrCreateWorld, UnloadWorld, BuildSparseTileData
]]

--[[
	Get or create a world by name.
	Checks cache first, then DataStore, then generates fresh.
	
	@param worldName: string — normalized world name
	@return table — world data
]]
function WorldService.GetOrCreateWorld(worldName: string): table
	local normalized = string.upper(string.gsub(worldName, "[^%w_]", ""))

	if #normalized == 0 then
		normalized = "MAIN"
	end
	if #normalized > 20 then
		normalized = string.sub(normalized, 1, 20)
	end

	-- Check cache first
	if worldCache[normalized] then
		return worldCache[normalized]
	end

	-- Use LoadWorld which handles DataStore lookups + generation + caching
	local worldData = WorldService.LoadWorld(normalized)

	-- Register with WorldRegistry (skip START — always local)
	if normalized ~= "START" then
		local WorldRegistry = require(script.Parent.WorldRegistry)
		WorldRegistry.Register(normalized)
		print(`[WorldService] Registered "{normalized}" with WorldRegistry`)
	end

	return worldData
end

--[[
	Unload a world from cache.
	Saves to DataStore first, then removes from cache.
	Does NOT unload the START world.
	
	@param worldName: string — world name
]]
function WorldService.UnloadWorld(worldName: string)
	local normalized = string.upper(worldName)

	if WorldService.IsSpecialWorld(normalized) then
		print(`[WorldService] Refusing to unload special world "{normalized}"`)
		return
	end

	local worldData = worldCache[normalized]
	if not worldData then
		print(`[WorldService] World "{normalized}" not in cache, nothing to unload`)
		return
	end

	-- Save to DataStore before removing
	local dropCount = worldData.drops and #worldData.drops or 0
	print(`[WorldService] Saving world "{normalized}" with {dropCount} drops`)
	local DataService = require(script.Parent.DataService)
	if DataService then
		DataService.SaveWorldData(normalized, worldData)
	end

	-- Unregister from ProfileStore auto-save tracking
	local ProfileStore = require(script.Parent.ProfileStore)
	if ProfileStore then
		ProfileStore.UnregisterWorld(normalized)
	end

	-- Deregister from WorldRegistry
	local WorldRegistry = require(script.Parent.WorldRegistry)
	if WorldRegistry then
		WorldRegistry.Deregister(normalized)
		print(`[WorldService] Deregistered "{normalized}" from WorldRegistry`)
	end

	-- Clear server-side drop Parts and folder for this world
	local DropService = require(script.Parent.DropService)
	if DropService then
		DropService.ClearWorldDrops(normalized)
		print(`[WorldService] Cleared drops for unloaded world "{normalized}"`)
	end

	-- Remove from cache
	worldCache[normalized] = nil
	print(`[WorldService] Unloaded world "{normalized}" from cache`)
end

--[[
	Get all world names currently in cache.
	@return { string } — array of world names
]]
function WorldService.GetAllActiveWorlds(): { string }
	local result: { string } = {}
	for name in pairs(worldCache) do
		table.insert(result, name)
	end
	return result
end

--[[
	Build sparse tile data for client transmission.
	Only exports tiles that differ from generated defaults.
	Format: { { i: number, fg: number?, bg: number?, hp: number?, treeData: table? } }
	
	@param worldData: table — spawned world data
	@return { table } — sparse tile array
]]
function WorldService.BuildSparseTileData(worldData: table): { table }
	if not worldData or not worldData.tiles then
		return {}
	end

	local tiles = worldData.tiles
	local generationSeed = worldData.generationSeed or 0
	local sparseData: { table } = {}

	for i, tile in ipairs(tiles) do
		local x = (i - 1) % WorldConfig.WORLD_WIDTH
		local y = math.floor((i - 1) / WorldConfig.WORLD_WIDTH)

		-- Check if this tile differs from default
		local isModified = false
		if tile.treeData then
			isModified = true
		else
			local defaultFg, defaultBg, defaultHp = WorldService._getDefaultTileState(x, y, generationSeed)
			if tile.fg ~= defaultFg or tile.bg ~= defaultBg or tile.hp ~= defaultHp then
				isModified = true
			end
		end

		if isModified then
			local entry: { i: number, fg: number?, bg: number?, hp: number?, treeData: table?, fgExtra: table? } = {
				i = i,
				fg = tile.fg,
				bg = tile.bg,
				hp = tile.hp,
			}
			if tile.treeData then entry.treeData = tile.treeData end
			if tile.fgExtra then entry.fgExtra = tile.fgExtra end

			table.insert(sparseData, entry)
		end
	end

	return sparseData
end

--[[
	Get the default tile state for a position in a generated world.
	Matches DataService._getDefaultTileState logic.
	
	@param x: number — tile X
	@param y: number — tile Y (0-indexed from top)
	@param generationSeed: number — world's generation seed
	@return (number, number, number) — fg, bg, hp
]]
function WorldService._getDefaultTileState(x: number, y: number, generationSeed: number): (number, number, number)
	-- Layer constants (0-indexed)
	local LAYER_SURFACE_Y = 5
	local LAYER_UNDERGROUND_END = 34
	local LAYER_DEEP_START = 35
	local LAYER_DEEP_END = 49
	local LAYER_LAVA_START = 50
	local LAYER_LAVA_END = 53
	local LAYER_BEDROCK_START = 54
	local LAYER_BEDROCK_END = 59

	local doorX = math.floor(WorldConfig.WORLD_WIDTH / 2)

	-- Main Door check (flat surface at Y=5)
	if x == doorX and y == LAYER_SURFACE_Y then
		return 6, 0, 99999
	end
	if x == doorX and y == LAYER_SURFACE_Y + 1 then
		return 5, 0, 99999
	end

	if y >= LAYER_BEDROCK_START and y <= LAYER_BEDROCK_END then
		return 5, 0, 99999
	elseif y >= LAYER_LAVA_START and y <= LAYER_LAVA_END then
		-- Lava zone: mix of Rock and Dirt, NO empty spaces
		local rng = Random.new(generationSeed + x * 1000 + y)
		local fgBlock = 2
		if rng:NextNumber() < 0.4 then fgBlock = 1 end
		local hp = ItemDatabase.GetItem(fgBlock).hp
		return fgBlock, 4, hp
	elseif y >= LAYER_DEEP_START and y <= LAYER_DEEP_END then
		return 2, 3, ItemDatabase.GetItem(2).hp
	elseif y >= 6 and y <= LAYER_UNDERGROUND_END then
		local rng = Random.new(generationSeed + x * 1000 + y)
		local fg = 1
		if rng:NextNumber() < 0.08 then fg = 2 end
		return fg, 3, ItemDatabase.GetItem(fg).hp
	elseif y == LAYER_SURFACE_Y then
		return 1, 0, ItemDatabase.GetItem(1).hp
	else
		return 0, 0, 0
	end
end

--[[
	Check if a world name is a special world (never unloaded, always kept warm).
	@param worldName: string
	@return boolean
]]
function WorldService.IsSpecialWorld(worldName: string): boolean
	return SPECIAL_WORLDS[string.upper(worldName)] == true
end

--[[
	Apply START-world-specific overrides to a freshly generated world.
	START world features:
	- Flat surface (no terrain height variation)
	- No lava zone
	- Welcome Sign block at center surface
	- Starter Dirt/Rock tiles scattered near spawn
]]
local function applyStartWorldOverrides(worldData: table)
	local tiles = worldData.tiles
	local WORLD_WIDTH = WorldConfig.WORLD_WIDTH
	local WORLD_HEIGHT = WorldConfig.WORLD_HEIGHT
	local doorX = math.floor(WORLD_WIDTH / 2)
	local surfaceY = 5  -- START has flat surface at Y=5

	-- 1. Surface is already flat from generation, just ensure no stray blocks above
	for x = 0, WORLD_WIDTH - 1 do
		if surfaceY > 0 then
			local aboveTile = tiles[x + (surfaceY - 1) * WORLD_WIDTH + 1]
			if aboveTile and aboveTile.fg ~= 0 and aboveTile.fg ~= 6 then
				aboveTile.fg = 0
				aboveTile.bg = 0
				aboveTile.hp = 0
			end
		end
	end

	-- 2. Remove lava zone (Y 50-53): convert to Rock/Cave Background
	for x = 0, WORLD_WIDTH - 1 do
		for y = 50, 53 do
			local tile = tiles[x + y * WORLD_WIDTH + 1]
			if tile then
				if tile.bg == 4 then
					tile.bg = 3
				end
				if tile.fg == 0 then
					tile.fg = 2
					tile.hp = ItemDatabase.GetItem(2).hp
				end
			end
		end
	end

	-- 3. Ensure surface tiles are all Dirt (no stray blocks)
	-- (Welcome Sign and starter rocks removed — user wants only flat surface)

	print("[WorldService] Applied START world overrides (flat surface, no lava, no floating blocks)")
end

--[[
	Initialize WorldService
]]
function WorldService.Init()
	-- Generate the START world on boot (never unloaded)
	local startWorld = WorldService.GetOrCreateWorld("START")
	if startWorld then
		applyStartWorldOverrides(startWorld)
	end
	print("[WorldService] Initialized — START world cached")
end

return WorldService
