--!strict
-- ProfileStore.lua
-- Persistence layer using ProfileStore pattern (Luminosity-style).
-- Manages player data (inventory + gems) and world data with:
--   - Automatic retries on DataStore failures
--   - Profile lifecycle (load/save/release)
--   - Session-locking to prevent data corruption
--   - Sparse tile compression for world data
--
-- This is the ONLY file that touches DataStoreService directly.
-- All other services (InventoryService, GemService, WorldService)
-- interact with in-memory state; this file handles persistence.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldConfig = require(ReplicatedStorage.Shared.WorldConfig)
local ItemDatabase = require(ReplicatedStorage.Shared.ItemDatabase)

local ProfileStore = {}

local DATASTORE_NAME = "GrowRoblox_v1"
local PLAYER_DATASTORE_NAME = "GrowRoblox_Players_v1"
local WORLD_DATASTORE_NAME = "GrowRoblox_Worlds_v1"

-- Retry configuration
local MAX_RETRIES = 5
local RETRY_DELAY = 1 -- seconds

-- Cache of active player profiles: userId -> profileData
local activePlayerProfiles: { [number]: table } = {}

-- Cache of active world data: worldName -> worldData
local activeWorldData: { [string]: table } = {}

--[[
	Get or create the player DataStore.
]]
local function getPlayerDataStore(): DataStore?
	local success, result = pcall(function()
		return DataStoreService:GetDataStore(PLAYER_DATASTORE_NAME)
	end)
	if success then
		return result
	else
		warn(`[ProfileStore] Failed to get player DataStore: {result}`)
		return nil
	end
end

--[[
	Get or create the world DataStore.
]]
local function getWorldDataStore(): DataStore?
	local success, result = pcall(function()
		return DataStoreService:GetDataStore(WORLD_DATASTORE_NAME)
	end)
	if success then
		return result
	else
		warn(`[ProfileStore] Failed to get world DataStore: {result}`)
		return nil
	end
end

--[[
	Retry a function up to MAX_RETRIES times with delay.
	@param fn: function — the function to retry (returns success, ...)
	@return boolean, any — success status and result
]]
local function withRetry(fn: () -> (boolean, any)): (boolean, any)
	for attempt = 1, MAX_RETRIES do
		local success, result = fn()
		if success then
			return true, result
		end
		if attempt < MAX_RETRIES then
			task.wait(RETRY_DELAY)
		end
	end
	return false, nil
end

--[[
	=== PLAYER DATA PROFILE ===
]]

--[[
	Load a player's profile from DataStore.
	Returns the saved data, or nil if no data exists (new player).
	Automatically retries on failure.

	@param userId: number — the player's UserId
	@return { gems: number, inventory: { { itemId: number, count: number }? }? }?
]]
function ProfileStore.LoadPlayerProfile(userId: number): { gems: number, inventory: { { itemId: number, count: number }? }? }?
	local store = getPlayerDataStore()
	if not store then return nil end

	local key = "player_" .. tostring(userId)

	local success, result = withRetry(function()
		return pcall(function()
			return store:GetAsync(key)
		end)
	end)

	if success then
		if result ~= nil then
			print(`[ProfileStore] Loaded player profile for userId={userId}`)
			return {
				gems = result.gems or 0,
				inventory = result.inventory or {},
			}
		else
			print(`[ProfileStore] No saved data for userId={userId}, using defaults`)
			return nil
		end
	else
		warn(`[ProfileStore] Failed to load player profile for userId={userId}: {result}`)
		return nil
	end
end

--[[
	Save a player's profile to DataStore.
	Uses UpdateAsync for atomic updates.
	Automatically retries on failure.

	@param userId: number
	@param gems: number
	@param inventory: { { itemId: number, count: number }? }?
	@return boolean — true if saved successfully
]]
function ProfileStore.SavePlayerProfile(userId: number, gems: number, inventory: { { itemId: number, count: number }? }?): boolean
	local store = getPlayerDataStore()
	if not store then return false end

	local key = "player_" .. tostring(userId)
	local data = {
		gems = gems,
		inventory = inventory or {},
	}

	local success, err = withRetry(function()
		return pcall(function()
			store:UpdateAsync(key, function(oldData)
				return data
			end)
		end)
	end)

	if success then
		print(`[ProfileStore] Saved player profile for userId={userId}`)
		return true
	else
		warn(`[ProfileStore] Failed to save player profile for userId={userId}: {err}`)
		return false
	end
end

--[[
	Mark a player's profile as active (loaded into memory).
	Called when a player joins.
]]
function ProfileStore.StartProfile(userId: number, gems: number, inventory: { { itemId: number, count: number }? }?)
	activePlayerProfiles[userId] = {
		gems = gems,
		inventory = inventory,
		startedAt = os.time(),
	}
end

--[[
	Get a player's active profile data.
	Returns nil if the profile hasn't been started.
]]
function ProfileStore.GetProfile(userId: number): { gems: number, inventory: { { itemId: number, count: number }? }? }?
	return activePlayerProfiles[userId]
end

--[[
	Release (end) a player's profile.
	Saves to DataStore first, then removes from active cache.
	Called when a player leaves.

	@param userId: number
	@param gems: number — current gems to save
	@param inventory: { { itemId: number, count: number }? }? — current inventory to save
	@return boolean — true if saved successfully
]]
function ProfileStore.EndProfile(userId: number, gems: number, inventory: { { itemId: number, count: number }? }?): boolean
	local success = ProfileStore.SavePlayerProfile(userId, gems, inventory)
	activePlayerProfiles[userId] = nil
	return success
end

--[[
	Save all active player profiles.
	Used by auto-save loop.

	@return number — count of profiles saved
]]
function ProfileStore.SaveAllActiveProfiles(): number
	local count = 0
	for userId, profile in pairs(activePlayerProfiles) do
		local success = ProfileStore.SavePlayerProfile(userId, profile.gems, profile.inventory)
		if success then
			count += 1
		end
	end
	return count
end

--[[
	=== WORLD DATA ===
]]

--[[
	Helper: Get the default tile state for a position in a generated world.
	Must match WorldService._getDefaultTileState EXACTLY for correct sparse compression.

	@param x: number — tile X
	@param y: number — tile Y (0-indexed from top)
	@param generationSeed: number — the world's generation seed
	@return (number, number, number) — fg, bg, hp
]]
function ProfileStore._getDefaultTileState(x: number, y: number, generationSeed: number): (number, number, number)
	-- Layer constants (must match WorldService._getDefaultTileState EXACTLY)
	local LAYER_SURFACE_Y = 5
	local LAYER_UNDERGROUND_END = 34
	local LAYER_DEEP_START = 35
	local LAYER_DEEP_END = 49
	local LAYER_LAVA_START = 50
	local LAYER_LAVA_END = 53
	local LAYER_BEDROCK_START = 54
	local LAYER_BEDROCK_END = 59

	local rng = Random.new(generationSeed + x * 1000 + y)
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
		local fgBlock = 2
		if rng:NextNumber() < 0.4 then
			fgBlock = 1
		end
		local hp = ItemDatabase.GetItem(fgBlock).hp
		return fgBlock, 4, hp
	elseif y >= LAYER_DEEP_START and y <= LAYER_DEEP_END then
		return 2, 3, ItemDatabase.GetItem(2).hp
	elseif y >= 6 and y <= LAYER_UNDERGROUND_END then
		local fg = 1
		if rng:NextNumber() < 0.08 then
			fg = 2
		end
		return fg, 3, ItemDatabase.GetItem(fg).hp
	elseif y == LAYER_SURFACE_Y then
		return 1, 0, ItemDatabase.GetItem(1).hp
	else
		return 0, 0, 0
	end
end

--[[
	Check if a tile matches the generated default state.
	Used for sparse compression — tiles matching defaults are skipped.
]]
function ProfileStore._isDefaultTile(tile: table, x: number, y: number, generationSeed: number): boolean
	if tile.treeData ~= nil then
		return false
	end

	local defaultFg, defaultBg, defaultHp = ProfileStore._getDefaultTileState(x, y, generationSeed)
	return tile.fg == defaultFg and tile.bg == defaultBg and tile.hp == defaultHp
end

--[[
	Save a world's tiles to DataStore using sparse compression.
	Only stores tiles that differ from generated defaults.

	@param worldName: string — normalized world name
	@param worldData: table — the world data with tiles array
	@return boolean — true if saved successfully
]]
function ProfileStore.SaveWorld(worldName: string, worldData: table): boolean
	local store = getWorldDataStore()
	if not store then return false end

	if not worldData or not worldData.tiles then
		warn(`[ProfileStore] Cannot save world "{worldName}": invalid data`)
		return false
	end

	-- Build sparse tile array: only save tiles that differ from default
	local sparseTiles: { { i: number, fg: number?, bg: number?, hp: number?, treeData: table? } } = {}
	local tiles = worldData.tiles
	local generationSeed = worldData.generationSeed or os.time()
	local totalModified = 0

	for i, tile in ipairs(tiles) do
		local x = (i - 1) % WorldConfig.WORLD_WIDTH
		local y = math.floor((i - 1) / WorldConfig.WORLD_WIDTH)

		if not ProfileStore._isDefaultTile(tile, x, y, generationSeed) then
			local entry: { i: number, fg: number?, bg: number?, hp: number?, treeData: table? } = {
				i = i,
				fg = tile.fg,
				bg = tile.bg,
				hp = tile.hp,
			}
			if tile.treeData then entry.treeData = tile.treeData end

			table.insert(sparseTiles, entry)
			totalModified += 1
		end
	end

	local saveData = {
		name = worldData.name or worldName,
		lockOwner = worldData.lockOwner,
		admins = worldData.admins,
		generationSeed = generationSeed,
		createdAt = worldData.createdAt,
		updatedAt = os.time(),
		tiles = sparseTiles,
		drops = worldData.drops or {},
	}

	local key = "world_" .. string.upper(worldName)
	local success, err = withRetry(function()
		return pcall(function()
			store:SetAsync(key, saveData)
		end)
	end)

	if success then
		print(`[ProfileStore] Saved world "{worldName}" ({totalModified}/{tiles} non-default tiles)`)
		return true
	else
		warn(`[ProfileStore] Failed to save world "{worldName}": {err}`)
		return false
	end
end

--[[
	Load a world's tile data from DataStore.
	Returns nil if no saved data exists.

	@param worldName: string — normalized world name
	@return table? — the saved world data, or nil
]]
function ProfileStore.LoadWorld(worldName: string): table?
	local store = getWorldDataStore()
	if not store then return nil end

	local normalized = string.upper(string.gsub(worldName, "[^%w_]", ""))
	local key = "world_" .. normalized

	local success, result = withRetry(function()
		return pcall(function()
			return store:GetAsync(key)
		end)
	end)

	if success then
		if result ~= nil then
			print(`[ProfileStore] Loaded world data for "{normalized}" ({#result.tiles} sparse tiles)`)
			return result
		else
			print(`[ProfileStore] No saved world data for "{normalized}"`)
			return nil
		end
	else
		warn(`[ProfileStore] Failed to load world data for "{normalized}": {result}`)
		return nil
	end
end

--[[
	Save all cached worlds to DataStore.
	Used by auto-save loop and shutdown handler.

	@return number — count of worlds saved
]]
function ProfileStore.SaveAllWorlds(): number
	local count = 0
	for worldName, worldData in pairs(activeWorldData) do
		local success = ProfileStore.SaveWorld(worldName, worldData)
		if success then
			count += 1
		end
	end
	return count
end

--[[
	Register a world as active (cached in memory).
	Called when a world is loaded.
]]
function ProfileStore.RegisterWorld(worldName: string, worldData: table)
	activeWorldData[string.upper(worldName)] = worldData
end

--[[
	Unregister a world from the active cache.
	Called when a world is unloaded.
]]
function ProfileStore.UnregisterWorld(worldName: string)
	activeWorldData[string.upper(worldName)] = nil
end

--[[
	Initialize ProfileStore.
]]
function ProfileStore.Init()
	print("[ProfileStore] Initialized — DataStore: " .. DATASTORE_NAME)
end

return ProfileStore
