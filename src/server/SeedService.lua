--!strict
-- SeedService.lua
-- Server-side seed planting, harvesting, and growth tracking
-- 2D tile-based tree system (Growtopia-style)
-- Calls SpliceService when planting a different seed on an existing tree

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local ItemDatabase = require(ReplicatedStorage.Shared.ItemDatabase)
local SpliceRecipes = require(ReplicatedStorage.Shared.SpliceRecipes)
local WorldConfig = require(ReplicatedStorage.Shared.WorldConfig)

local LockService = require(script.Parent.LockService)
local DropService = require(script.Parent.DropService)
local PlayerManager = require(script.Parent.PlayerManager)
local SpliceService = require(script.Parent.SpliceService)
local WorldService = require(script.Parent.WorldService)

local SeedService = {}

-- Constants
local DEFAULT_GEM_DROP_MAX = 5

--[[
	Calculate the growth percentage of a tree tile.
	Returns 0.0 to 1.0, clamped.

	@param tile: table — the tile with treeData
	@return number — growth percentage (0.0 to 1.0)
]]
function SeedService.GetGrowthPercent(tile: table): number
	if not tile or not tile.treeData then
		return 0.0
	end

	local treeData = tile.treeData
	if not treeData.seedId or not treeData.plantedAt then
		return 0.0
	end

	local growthTime = treeData.growthTime
	if not growthTime or growthTime <= 0 then
		return 1.0 -- Instant growth
	end

	local elapsed = os.time() - treeData.plantedAt
	local percent = elapsed / growthTime
	return math.min(math.max(percent, 0.0), 1.0)
end

--[[
	Check if a tree is fully grown.

	@param tile: table — the tile with treeData
	@return boolean — true if fully grown
]]
function SeedService._isFullyGrown(tile: table): boolean
	return SeedService.GetGrowthPercent(tile) >= 1.0
end

--[[
	Plant a seed on a tile.

	Validation chain:
	1. Player exists
	2. Tile coordinates are in bounds
	3. Tile has no foreground block (fg must be 0 for initial planting)
	4. Tile below has a solid foreground block
	5. Tile is within reach (4 tiles)
	6. LockService.CanModify returns true
	7. Player has the seed in inventory
	8. Check tile.treeData:
	   a. If tile has treeData with a DIFFERENT seedId → call SpliceService.TrySplice
	   b. If tile has treeData with the SAME seedId → return false, "Already planted"
	   c. If no treeData → plant fresh

	On fresh plant success:
	- Set tile.treeData = { seedId, plantedAt = os.time(), growthTime }
	- Consume 1 seed from player inventory
	- Return true, "Seed planted"

	@param player: Player — the player planting
	@param worldData: table — the world data
	@param tileX: number — target X
	@param tileY: number — target Y
	@param seedId: number — the seed item ID to plant
	@return boolean, string — success status and message
]]
function SeedService.PlantSeed(player: Player, worldData: table, tileX: number, tileY: number, seedId: number): (boolean, string)
	-- 1. Validate player
	if not player or not player.UserId then
		return false, "Invalid player"
	end

	-- 2. Validate seedId
	if not seedId or seedId <= 0 then
		return false, "Invalid seed"
	end

	-- 3. Validate tile coordinates
	if not WorldConfig.IsValidPosition(tileX, tileY) then
		return false, "Invalid position"
	end

	-- 4. Validate worldData
	if not worldData or not worldData.tiles then
		return false, "Invalid world"
	end

	-- 5. Get the tile
	local tileIndex = tileX + tileY * WorldConfig.WORLD_WIDTH + 1
	local tile = worldData.tiles[tileIndex]
	if not tile then
		return false, "Invalid tile"
	end

	-- 6. Validate the seed exists in ItemDatabase
	local seedDef = ItemDatabase.GetSeed(seedId)
	if not seedDef then
		warn(`[SeedService] {player.Name} tried to plant unknown seed ID {seedId}`)
		return false, "Unknown seed"
	end

	-- 7. Check if the tile already has a tree planted
	if tile.treeData then
		local existingSeedId = tile.treeData.seedId

		-- 7a. If same seed type — already planted
		if existingSeedId == seedId then
			return false, "Already planted"
		end

		-- 7b. If different seed — attempt splice via SpliceService
		-- Do NOT consume the incoming seed yet; SpliceService handles consumption logic
		local success, resultBlockId = SpliceService.TrySplice(worldData, tileX, tileY, seedId)
		if success then
			-- Splice succeeded — consume the incoming seed from inventory
			PlayerManager.RemoveItem(player, seedId, 1)
			print(`[SeedService] Splice triggered by {player.Name} at ({tileX}, {tileY}): seed {existingSeedId} + {seedId} = {resultBlockId}`)
			return true, "Splice successful!"
		else
			-- Splice failed — do NOT consume seed
			return false, "Splice failed: no matching recipe"
		end
	end

	-- 8. Validate reach
	local playerTileX, playerTileY = WorldConfig.GetPlayerTilePosition(player)
	if playerTileX == nil or playerTileY == nil then
		return false, "Character not loaded"
	end

	local distance = WorldConfig.GetTileDistance(playerTileX, playerTileY, tileX, tileY)
	if distance > WorldConfig.PLAYER_REACH then
		return false, "Too far away"
	end

	-- 9. Validate lock access
	if not LockService.CanModify(player, worldData, tileX, tileY) then
		return false, "You don't have permission here"
	end

	-- 10. Check if the tile fg is empty (required for fresh planting)
	if tile.fg ~= 0 and tile.fg ~= nil then
		return false, "Foreground slot is occupied"
	end

	-- 11. Check if tile below has a solid foreground block
	if tileY + 1 < WorldConfig.WORLD_HEIGHT then
		local belowIndex = tileX + (tileY + 1) * WorldConfig.WORLD_WIDTH + 1
		local belowTile = worldData.tiles[belowIndex]
		if not belowTile or belowTile.fg == 0 or belowTile.fg == nil then
			return false, "Must plant on a solid surface"
		end
	end

	-- 12. Check if player has the seed in inventory
	if not PlayerManager.HasItem(player, seedId, 1) then
		return false, "You don't have that seed"
	end

	-- === FRESH PLANT ===

	-- Determine the block ID associated with this seed for the visual foreground
	local blockId = ItemDatabase.GetBlockIdForSeed(seedId)
	if not blockId then
		warn(`[SeedService] Seed {seedId} has no associated block, using seed ID as fallback`)
		blockId = seedId
	end

	local blockDef = ItemDatabase.GetItem(blockId)

	-- Place the block in the foreground
	tile.fg = blockId
	tile.hp = (blockDef and blockDef.hp) or 1

	-- Set up tree data
	local growthTime = seedDef.growthTime or WorldConfig.DEFAULT_GROWTH_TIME
	tile.treeData = {
		seedId = seedId,
		plantedAt = os.time(),
		growthTime = growthTime,
	}

	-- Consume 1 seed from inventory
	PlayerManager.RemoveItem(player, seedId, 1)

	worldData.updatedAt = os.time()

	print(`[SeedService] {player.Name} planted {seedDef.name} at ({tileX}, {tileY}), grows in {growthTime}s`)
	return true, "Seed planted!"
end

--[[
	Harvest a fully grown tree at a tile.

	Validation chain:
	1. Player exists
	2. Tile coordinates are in bounds
	3. Tile has treeData
	4. Tree is fully grown (os.time() >= plantedAt + growthTime)
	5. Player has lock access
	6. Within reach (4 tiles)

	On success:
	- Drop 4-6 block items, 1-2 seeds, 1-5 gems (random)
	- Clear tile.treeData
	- Clear tile.fg (tree is gone)
	- Spawn physical world drops via DropService.SpawnDrop

	@param player: Player — the player harvesting
	@param worldData: table — the world data
	@param tileX: number — target X
	@param tileY: number — target Y
	@return boolean, { { itemId: number, count: number } }? — success and dropped items list
]]
function SeedService.HarvestTree(player: Player, worldData: table, tileX: number, tileY: number): (boolean, { { itemId: number, count: number } }?)
	-- 1. Validate player
	if not player or not player.UserId then
		return false, nil
	end

	-- 2. Validate tile coordinates
	if not WorldConfig.IsValidPosition(tileX, tileY) then
		return false, nil
	end

	-- 3. Validate worldData
	if not worldData or not worldData.tiles then
		return false, nil
	end

	-- 4. Get the tile
	local tileIndex = tileX + tileY * WorldConfig.WORLD_WIDTH + 1
	local tile = worldData.tiles[tileIndex]
	if not tile then
		return false, nil
	end

	-- 5. Check for treeData
	local treeData = tile.treeData
	if not treeData then
		return false, nil -- Nothing to harvest
	end

	-- 6. Check if tree is fully grown
	if not SeedService._isFullyGrown(tile) then
		return false, nil -- Tree is still growing
	end

	-- 7. Validate reach
	local playerTileX, playerTileY = WorldConfig.GetPlayerTilePosition(player)
	if playerTileX == nil or playerTileY == nil then
		return false, nil
	end

	local distance = WorldConfig.GetTileDistance(playerTileX, playerTileY, tileX, tileY)
	if distance > WorldConfig.PLAYER_REACH then
		return false, nil
	end

	-- 8. Validate lock access
	if not LockService.CanModify(player, worldData, tileX, tileY) then
		return false, nil
	end

	-- === HARVEST — GENERATE DROPS ===

	local seedId = treeData.seedId
	local blockId = ItemDatabase.GetBlockIdForSeed(seedId)

	local drops: { [number]: number } = {}
	local rng = Random.new()

	-- Drop 4-6 block items
	local blockDropCount = rng:NextInteger(4, 6)
	if blockId then
		drops[blockId] = (drops[blockId] or 0) + blockDropCount
	else
		-- Fallback: drop seed as block if no mapping
		drops[seedId] = (drops[seedId] or 0) + blockDropCount
	end

	-- Drop 1-2 seeds (with seedYield probability for farmable seeds)
	local seedDef = ItemDatabase.GetSeed(seedId)
	local seedDropCount = 0
	if seedDef and seedDef.seedYield then
		-- Farmable seed: use seedYield probability to return the seed
		if rng:NextNumber() <= seedDef.seedYield then
			seedDropCount = 1
		end
	else
		-- Default: always return 1-2 seeds
		seedDropCount = rng:NextInteger(1, 2)
	end
	if seedDropCount > 0 then
		drops[seedId] = (drops[seedId] or 0) + seedDropCount
	end

	-- Drop gems — farmable seeds use special payout overrides
	local farmableGemPayouts = {
		[54] = { min = 40, max = 80 },   -- Ashveil Seed (2hr)
		[55] = { min = 150, max = 280 }, -- Duskbloom Seed (8hr)
		[56] = { min = 500, max = 900 }, -- Sunstone Seed (24hr)
	}
	local gemDropCount = 0
	if farmableGemPayouts[seedId] then
		local payout = farmableGemPayouts[seedId]
		gemDropCount = rng:NextInteger(payout.min, payout.max)
		print(`[SeedService] Farmable seed #{seedId} harvested — gem payout: {gemDropCount}`)
	else
		gemDropCount = rng:NextInteger(1, DEFAULT_GEM_DROP_MAX)
	end
	drops[28] = (drops[28] or 0) + gemDropCount

	-- === CLEAR THE TILE ===
	tile.treeData = nil
	tile.fg = 0
	tile.hp = 0

	worldData.updatedAt = os.time()

	-- Spawn physical drops in the world using math-based gravity.
	-- DropService.SpawnDrop scans worldData.tiles downward from the harvest point
	-- to find the nearest solid surface, then places the drop anchored there.
	-- No native physics needed — the server's Workspace has no physical tiles.
	for itemId, count in pairs(drops) do
		DropService.SpawnDrop(itemId, count, worldData, tileX, tileY)
	end

	print(`[SeedService] {player.Name} harvested tree at ({tileX}, {tileY}) — {blockDropCount} blocks, {seedDropCount} seeds, {gemDropCount} gems`)
	return true, nil
end

--[[
	Start the growth update loop.
	Runs every 10 seconds (task.spawn loop).
	Scans all worlds in cache for tiles with treeData.
	Broadcasts batched growth updates per world (not per-tile spam).

	This must be called ONCE from init.server.luau.
]]
function SeedService.StartGrowthLoop()
	task.spawn(function()
		while true do
			task.wait(10)

			local allWorlds = WorldService.GetAllWorlds()
			if not allWorlds then
				continue
			end

			for worldName, worldData in pairs(allWorlds) do
				if not worldData or not worldData.tiles then
					continue
				end

				-- Collect all changed tiles in this world for batched broadcast
				local changedTiles: { { x: number, y: number, growthPercent: number } } = {}
				local tiles = worldData.tiles

				for y = 0, WorldConfig.WORLD_HEIGHT - 1 do
					for x = 0, WorldConfig.WORLD_WIDTH - 1 do
						local tileIndex = x + y * WorldConfig.WORLD_WIDTH + 1
						local tile = tiles[tileIndex]
						if tile and tile.treeData then
							local growthPercent = SeedService.GetGrowthPercent(tile)
							table.insert(changedTiles, {
								x = x,
								y = y,
								growthPercent = growthPercent,
							})
						end
					end
				end

				-- Only send update if there are growing trees
				-- Uses BroadcastToWorld to scope the event to players in this specific world,
				-- preventing growth updates from leaking to players in other worlds.
				if #changedTiles > 0 then
					PlayerManager.BroadcastToWorld(worldName, "GrowthUpdate", worldName, changedTiles)
				end
			end
		end
	end)

	print("[SeedService] Growth loop started (10s interval)")
end

--[[
	Initialize SeedService.
]]
function SeedService.Init()
	print("[SeedService] Initialized")
end

return SeedService
