--!strict
-- SpliceService.lua
-- Server-side seed splicing logic
-- Called by SeedService when planting a seed on a tile that already has a different seed growing
-- No circular dependency: SpliceService does NOT require SeedService

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local ItemDatabase = require(ReplicatedStorage.Shared.ItemDatabase)
local SpliceRecipes = require(ReplicatedStorage.Shared.SpliceRecipes)
local RemoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)
local WorldConfig = require(ReplicatedStorage.Shared.WorldConfig)

local SpliceService = {}

--[[
	Attempt to splice an incoming seed with an already-planted seed on a tile.
	The tile must have treeData with a seedId (the "existing" seed).

	Algorithm:
	1. Read existing tile.treeData.seedId as seedA
	2. incomingSeedId is seedB
	3. Look up SpliceRecipes.GetResult(seedA, seedB)
	4. On hit:
	   a. Convert the recipe's result block ID back to its seed ID
	   b. Update tile.treeData.seedId = new seed ID
	   c. Reset plantedAt = os.time()
	   d. Set growthTime from the new seed's ItemDatabase entry
	   e. Broadcast success to all players
	   f. Return true, result item ID
	5. On miss:
	   a. Do NOT consume the incoming seed
	   b. Broadcast failure to all players
	   c. Return false, nil

	@param worldData: table — the world data (needs .name for broadcasting)
	@param tileX: number — tile X coordinate
	@param tileY: number — tile Y coordinate
	@param incomingSeedId: number — the seed being spliced in
	@return boolean, number? — true + result block ID on success, false + nil on miss
]]
function SpliceService.TrySplice(worldData: table, tileX: number, tileY: number, incomingSeedId: number): (boolean, number?)
	-- Validate worldData
	if not worldData or not worldData.tiles then
		return false, nil
	end

	-- Validate tile coordinates
	if not WorldConfig.IsValidPosition(tileX, tileY) then
		return false, nil
	end

	-- Get the tile
	local tileIndex = tileX + tileY * WorldConfig.WORLD_WIDTH + 1
	local tile = worldData.tiles[tileIndex]

	-- Validate tile and treeData
	if not tile then
		return false, nil
	end

	local treeData = tile.treeData
	if not treeData then
		-- No tree data on this tile — nothing to splice with
		return false, nil
	end

	local existingSeedId = treeData.seedId
	if not existingSeedId or existingSeedId == 0 then
		return false, nil
	end

	-- The existing seed can't be the same as the incoming one (that's just planting the same type)
	if existingSeedId == incomingSeedId then
		return false, nil
	end

	-- SpliceRecipes stores recipes by block item IDs (1-30), not seed IDs (101-130).
	-- Convert both seeds to their parent block IDs before doing the lookup.
	-- Get the block ID for the existing seed (e.g., seed 101 → block 1 Dirt)
	local existingBlockId = ItemDatabase.GetBlockIdForSeed(existingSeedId)
	if not existingBlockId then
		warn(`[SpliceService] Existing seed {existingSeedId} has no parent block mapping`)
		return false, nil
	end

	-- Get the block ID for the incoming seed (e.g., seed 102 → block 2 Rock)
	-- If GetBlockIdForSeed returns nil, the incoming might already be a raw block ID
	local incomingBlockId = ItemDatabase.GetBlockIdForSeed(incomingSeedId) or incomingSeedId

	-- Look up the recipe using converted block IDs
	local resultBlockId = SpliceRecipes.GetResult(existingBlockId, incomingBlockId)

	if not resultBlockId then
		-- No recipe match — splice failed
		-- Broadcast failure message
		local incomingSeedDef = ItemDatabase.GetSeed(incomingSeedId)
		local existingSeedDef = ItemDatabase.GetSeed(existingSeedId)
		local incomingName = (incomingSeedDef and incomingSeedDef.name) or ("item " .. tostring(incomingSeedId))
		local existingName = (existingSeedDef and existingSeedDef.name) or ("item " .. tostring(existingSeedId))

		local worldName = worldData.name or "UNKNOWN"
		SpliceService._broadcastSpliceResult(worldName, false, incomingName, existingName)

		return false, nil
	end

	-- Splice succeeded! Convert result block ID to its seed ID
	local resultSeedId = ItemDatabase.GetSeedIdForBlock(resultBlockId)
	if not resultSeedId then
		warn(`[SpliceService] Result block {resultBlockId} has no seed mapping`)
		return false, nil
	end

	-- Get the seed definition for growth time
	local resultSeedDef = ItemDatabase.GetSeed(resultSeedId)
	if not resultSeedDef then
		warn(`[SpliceService] Result seed {resultSeedId} has no definition`)
		return false, nil
	end

	-- Update the tile's treeData: new seed, reset timer
	tile.treeData = {
		seedId = resultSeedId,
		plantedAt = os.time(),
		growthTime = resultSeedDef.growthTime or WorldConfig.DEFAULT_GROWTH_TIME,
	}

	-- Also place the resulting block's foreground item visually
	local resultItemDef = ItemDatabase.GetItem(resultBlockId)
	if resultItemDef and resultItemDef.type ~= WorldConfig.ItemTypes.BACKGROUND then
		tile.fg = resultBlockId
		tile.hp = resultItemDef.hp or 1
	end

	worldData.updatedAt = os.time()

	-- Broadcast success message
	local resultItemName = (resultItemDef and resultItemDef.name) or ("item " .. tostring(resultBlockId))
	local worldName = worldData.name or "UNKNOWN"
	SpliceService._broadcastSpliceResult(worldName, true, resultItemName)

	print(`[SpliceService] Splice success: {existingSeedId} + {incomingSeedId} = {resultSeedId} ({resultItemName}) at ({tileX}, {tileY})`)
	return true, resultBlockId
end

--[[
	Broadcast splice result to all players.

	@param worldName: string — world name for context
	@param success: boolean — whether the splice succeeded
	@param ...: string — item name(s) for the message
]]
function SpliceService._broadcastSpliceResult(worldName: string, success: boolean, ...: string)
	local message: string
	if success then
		local resultName = ...
		message = `Splice successful! You created {resultName}!`
	else
		local incomingName, existingName = ...
		message = `Splice failed! {incomingName} + {existingName} does not produce a valid result.`
	end

	-- Fire to all players in the world using the new RemoteEvents system
	RemoteEvents.SpliceResult:FireAllClients(worldName, success, message)

	print(`[SpliceService] Broadcast to "{worldName}": {message}`)
end

--[[
	Initialize SpliceService.
]]
function SpliceService.Init()
	print("[SpliceService] Initialized")
end

return SpliceService
