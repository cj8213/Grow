--!strict
-- BlockService.lua
-- Server-side block place/break logic with permissions
-- Validates all inputs server-side (never trust the client)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local WorldConfig = require(ReplicatedStorage.Shared.WorldConfig)
local ItemDatabase = require(ReplicatedStorage.Shared.ItemDatabase)
local LockService = require(script.Parent.LockService)
local InventoryService = require(script.Parent.InventoryService)

-- PlayerManager handles inventory operations (AddItem, RemoveItem, HasItem)
local PlayerManager = require(script.Parent.PlayerManager)
local DropService = require(script.Parent.DropService)
local GemService = require(script.Parent.GemService)
local RemoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)

local BlockService = {}

-- Helper: get safe world name for broadcasts (fallback to "UNKNOWN")
local function safeWorldName(worldData: table): string
	return if worldData and worldData.name and #worldData.name > 0 then worldData.name else "UNKNOWN"
end

--[[
	Get the player's equipped tool damage.
	Checks the player's character for a Tool in hand.
	Defaults to fist damage (1) if no tool equipped.

	@param player: Player — the player
	@return number — damage value
]]
function BlockService._getEquippedDamage(player: Player): number
	local character = player.Character
	if not character then
		return 1 -- Default fist damage
	end

	-- Check for a Tool in the character's hand
	local tool = character:FindFirstChildOfClass("Tool")
	if not tool then
		return 1 -- No tool equipped, use fist
	end

	-- Look up the tool in ItemDatabase by name
	local item = ItemDatabase.GetItemByName(tool.Name)
	if item and item.damage then
		return item.damage
	end

	return 1 -- Default to fist damage
end

--[[
	Roll for a random integer between min and max (inclusive).

	@param min: number — minimum value
	@param max: number — maximum value
	@return number — random integer
]]
function BlockService._randomRange(min: number, max: number): number
	if min >= max then
		return min
	end
	return Random.new():NextInteger(min, max)
end

--[[
	Roll whether a seed drops when breaking a block.

	@param seedDropChance: number — probability (0.0 to 1.0)
	@return boolean — true if seed drops
]]
function BlockService._rollSeedDrop(seedDropChance: number): boolean
	return Random.new():NextNumber() < seedDropChance
end

--[[
	Break a block at the given tile coordinates.
	Validates all conditions server-side.

	Validation chain:
	1. Player exists and has a character
	2. Tile coordinates are valid (in world bounds)
	3. Tile has a foreground block
	4. Tile is within reach (4 tiles)
	5. LockService.CanModify returns true
	6. Block is not indestructible (not bedrock/MainDoor)
	7. Reduce tile HP by equipped tool damage
	8. If HP <= 0: clear tile, roll drops, return items

	@param player: Player — the player breaking the block
	@param worldData: table — the world data containing the tile grid
	@param tileX: number — target tile X coordinate
	@param tileY: number — target tile Y coordinate
	@return boolean, { { itemId: number, count: number } }? — success status and dropped items list
]]
function BlockService.BreakBlock(player: Player, worldData: table, tileX: number, tileY: number): (boolean, { { itemId: number, count: number } }?)
	-- === VALIDATION ===

	-- 1. Validate player
	if not player or not player.UserId then
		warn("[BlockService] BreakBlock failed: invalid player")
		return false, nil
	end

	-- 2. Validate tile coordinates (bounds check)
	if not WorldConfig.IsValidPosition(tileX, tileY) then
		warn(`[BlockService] {player.Name} attempted break at invalid coords ({tileX}, {tileY})`)
		return false, nil
	end

	-- 3. Validate worldData
	if not worldData or not worldData.tiles then
		warn("[BlockService] BreakBlock failed: invalid world data")
		return false, nil
	end

	-- Get the tile
	local tileIndex = tileX + tileY * WorldConfig.WORLD_WIDTH + 1
	local tile = worldData.tiles[tileIndex]
	if not tile then
		warn("[BlockService] BreakBlock failed: tile not found")
		return false, nil
	end

	-- 4. Check if there's a foreground block to break
	local fgBlockId = tile.fg
	if fgBlockId == 0 or fgBlockId == nil then
		return false, nil -- No block to break
	end

	-- 5. Validate reach (max 4 tiles from player position)
	local playerTileX, playerTileY = WorldConfig.GetPlayerTilePosition(player)
	if playerTileX == nil or playerTileY == nil then
		warn(`[BlockService] {player.Name} has no character for reach check`)
		return false, nil
	end

	local distance = WorldConfig.GetTileDistance(playerTileX, playerTileY, tileX, tileY)
	if distance > WorldConfig.PLAYER_REACH then
		warn(`[BlockService] {player.Name} too far from break target: {distance} tiles (max {WorldConfig.PLAYER_REACH})`)
		return false, nil
	end

	-- 6. Validate lock access
	if not LockService.CanModify(player, worldData, tileX, tileY) then
		warn(`[BlockService] {player.Name} denied by LockService at ({tileX}, {tileY})`)
		return false, nil
	end

	-- 7. Look up the block definition
	local itemDef = ItemDatabase.GetItem(fgBlockId)
	if not itemDef then
		warn(`[BlockService] Unknown block ID {fgBlockId} at ({tileX}, {tileY})`)
		return false, nil
	end

	-- 8. Check if indestructible (Bedrock, Main Door)
	local breakable = ItemDatabase.IsBreakable(fgBlockId)
	if not breakable then
		return false, nil -- Cannot break indestructible blocks
	end

	-- 9. Enforce fist-only breaking: only the Fist (itemId 1000) can break blocks.
	-- Other tools (Axe 1001, Wrench 1002, Scissors 1003, Shovel 1004) cannot.
	-- Lock blocks (26, 27) are exempt since their break logic is handled specially.
	if fgBlockId ~= 26 and fgBlockId ~= 27 then
		local equippedItemId = InventoryService.GetEquippedItem(player)
		if equippedItemId ~= 1000 then
			-- Not using fist — block cannot be damaged by other tools
			return false, nil
		end
	end

	-- === DAMAGE CALCULATION ===

	-- Get equipped tool damage
	local damage = BlockService._getEquippedDamage(player)

	-- Reduce tile HP
	tile.hp = (tile.hp or itemDef.hp) - damage

	-- If HP is still above 0, block is damaged but not broken
	if tile.hp > 0 then
		return true, {} -- Block damaged but not broken, no drops yet
	end

	-- === BLOCK BROKEN — GENERATE DROPS ===
	-- NOTE: The block itself is NOT dropped. Breaking a block destroys it.
	-- Blocks are only obtained by harvesting grown trees (SeedService).
	-- Players only get a chance at seed drops and gem drops from breaking.

	local drops: { [number]: number } = {}

	-- Roll for seed drop
	if itemDef.seedDropChance and itemDef.seedDropChance > 0 and itemDef.seedId then
		if BlockService._rollSeedDrop(itemDef.seedDropChance) then
			drops[itemDef.seedId] = (drops[itemDef.seedId] or 0) + 1
		end
	end

	-- Award gems directly to balance via GemService (no physical drop — balance updated immediately)
	local gemsAwarded = GemService.AwardBlockBreakGems(player, itemId)

	-- Spawn visual gem drops (eye candy only — balance already updated)
	if gemsAwarded > 0 then
		DropService.SpawnGemDrops(gemsAwarded, worldData, tileX, tileY)
	end

	-- === SPECIAL: Breaking a World Lock (fg=26) returns the lock item ===
	if fgBlockId == 26 then
		local success, msg = LockService.RemoveWorldLock(player, worldData)
		if success then
			print(`[BlockService] World Lock broken by {player.Name} — world unlocked, lock returned`)
			-- Return the lock item directly to inventory (no physical drop)
			PlayerManager.AddItem(player, 26, 1)
		end
		tile.fg = 0
		tile.bg = tile.bg or 0
		tile.hp = 0
		worldData.updatedAt = os.time()

		-- Broadcast lock status change to all players in world
		PlayerManager.BroadcastToWorld(safeWorldName(worldData), "WorldLockStatus", false, nil)
		-- Broadcast updated lock zone visualization
		PlayerManager.BroadcastToWorld(safeWorldName(worldData), "LockZonesUpdated", LockService.BuildLockZonesData(worldData))
		-- Send updated inventory to the breaker
		local InventoryService = require(script.Parent.InventoryService)
		PlayerManager.FireToPlayer(player, "InventoryUpdated", InventoryService.GetInventory(player))
		return true, nil
	end

	-- === SPECIAL: Breaking a Small Lock (fg=27) removes the zone + returns the lock ===
	if fgBlockId == 27 then
		-- Use LockService to find which lock owns this tile and remove it
		local lockId, lockData = LockService.GetLockAt(worldData, tileX, tileY)
		local removalSuccess = false
		if lockId then
			-- Allow removal by the owner or a permanent admin
			local ok, msg = LockService.RemoveSmallLock(player, worldData, lockId)
			if ok then
				removalSuccess = true
				print(`[BlockService] Small lock "{lockId}" removed by {player.Name} at ({tileX}, {tileY})`)
			else
				warn(`[BlockService] Small lock removal failed for {player.Name}: {msg}`)
			end
		end

		-- Return the lock item directly to inventory
		PlayerManager.AddItem(player, 27, 1)
		tile.fg = 0
		tile.bg = tile.bg or 0
		tile.hp = 0
		worldData.updatedAt = os.time()
		local InventoryService = require(script.Parent.InventoryService)
		PlayerManager.FireToPlayer(player, "InventoryUpdated", InventoryService.GetInventory(player))
		-- Broadcast updated lock visualization (zones cleared if removal succeeded)
		PlayerManager.BroadcastToWorld(safeWorldName(worldData), "LockZonesUpdated", LockService.BuildLockZonesData(worldData))
		return true, nil
	end

	-- === TALL DOOR CHECK: also clear the other tile ===
	local clearedTallDoor = false
	if itemDef.isTallDoor == true then
		-- Check tile above (tileY-1) for matching itemId
		if tileY - 1 >= 0 then
			local aboveIndex = tileX + (tileY - 1) * WorldConfig.WORLD_WIDTH + 1
			local aboveTile = worldData.tiles[aboveIndex]
			if aboveTile and aboveTile.fg == fgBlockId then
				aboveTile.fg = 0
				aboveTile.hp = 0
				clearedTallDoor = true
			end
		end
		-- Check tile below (tileY+1) for matching itemId
		if tileY + 1 < WorldConfig.WORLD_HEIGHT then
			local belowIndex = tileX + (tileY + 1) * WorldConfig.WORLD_WIDTH + 1
			local belowTile = worldData.tiles[belowIndex]
			if belowTile and belowTile.fg == fgBlockId then
				belowTile.fg = 0
				belowTile.hp = 0
				clearedTallDoor = true
			end
		end
	end

	-- === CLEAR THE TILE ===
	tile.fg = 0
	tile.bg = tile.bg or 0
	tile.hp = 0

	-- Clear any tree data (if a tree was planted here)
	if tile.treeData then
		tile.treeData = nil
	end

	worldData.updatedAt = os.time()

	if clearedTallDoor then
		print(`[BlockService] Tall door {itemDef.name} broken at ({tileX}, {tileY}) — cleared both tiles`)
	end

	-- Spawn physical drops in the world using math-based gravity.
	local dropTypeCount = 0
	for _, _ in pairs(drops) do
		dropTypeCount += 1
	end

	for itemId, count in pairs(drops) do
		DropService.SpawnDrop(itemId, count, worldData, tileX, tileY)
	end

	print(`[BlockService] {player.Name} broke block {itemDef.name} at ({tileX}, {tileY}) — {dropTypeCount} drop types`)

	return true, nil
end

--[[
	Place a block at the given tile coordinates.
	Validates all conditions server-side.

	Validation chain:
	1. Player exists and is valid
	2. Item ID is valid
	3. Tile coordinates are in bounds
	4. World data is valid
	5. Tile exists at index
	6. Item definition exists
	7. Reject seeds (must use SeedService)
	8. Tile is within reach (4 tiles)
	9. Cannot place on player's own character tile
	10. Cannot place in spawn zone (2 tiles above spawn surface at door X)
	11. LockService.CanModify returns true
	12. Player has the item in inventory
	13. If item is a WorldLock/SmallLock: call LockService.PlaceWorldLock/PlaceSmallLock instead
	14. Determine layer (FG/BG) and place the item
	15. Consume 1 item from inventory

	@param player: Player — the player placing the block
	@param worldData: table — the world data containing the tile grid
	@param tileX: number — target tile X coordinate
	@param tileY: number — target tile Y coordinate
	@param itemId: number — the item ID to place
	@return boolean, string — success status and message
]]
function BlockService.PlaceBlock(player: Player, worldData: table, tileX: number, tileY: number, itemId: number): (boolean, string)
	-- === VALIDATION ===

	-- 1. Validate player
	if not player or not player.UserId then
		return false, "Invalid player"
	end

	-- 2. Validate itemId
	if not itemId or itemId <= 0 then
		return false, "Invalid item"
	end

	-- 3. Validate tile coordinates (bounds check)
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

	-- 6. Look up the item definition
	local itemDef = ItemDatabase.GetItem(itemId)
	if not itemDef then
		warn(`[BlockService] {player.Name} tried to place unknown itemId {itemId}`)
		return false, "Unknown item"
	end

	-- 7. Reject seeds — they belong in SeedService
	if itemDef.type == WorldConfig.ItemTypes.SEED then
		return false, "Seeds must be planted via SeedService"
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

	-- 9. Prevent placing blocks on the player's own character/rig
	if tileX == playerTileX and tileY == playerTileY then
		return false, "Cannot place a block on yourself"
	end

	-- 10. Prevent placing blocks in the spawn area
	local doorX = math.floor(WorldConfig.WORLD_WIDTH / 2)
	local surfaceY = 5
	if tileX == doorX and (tileY == surfaceY - 1 or tileY == surfaceY - 2) then
		return false, "Cannot place a block in the spawn area"
	end

	-- 11. Validate lock access
	if not LockService.CanModify(player, worldData, tileX, tileY) then
		return false, "You don't have permission here"
	end

	-- 12. Check if the player has the item in inventory
	if not PlayerManager.HasItem(player, itemId, 1) then
		return false, "You don't have that item"
	end

	-- 13. Handle lock items: World Lock and Small Locks
	if itemDef.type == WorldConfig.ItemTypes.LOCK then
		if itemId == 26 then -- World Lock (ID 26)
			-- Cannot place World Lock if there are Small Locks in this world
			if LockService.HasSmallLocks(worldData) then
				return false, "Remove all small locks first!"
			end
			local success, message = LockService.PlaceWorldLock(player, worldData)
			if not success then
				return false, message
			end
			-- Place a gold foreground block as the visual representation of the lock
			tile.fg = 26
			tile.hp = 20
			tile.bg = tile.bg or 0
			PlayerManager.RemoveItem(player, itemId, 1)
			worldData.updatedAt = os.time()
			-- Broadcast lock zone update
			PlayerManager.BroadcastToWorld(safeWorldName(worldData), "LockZonesUpdated", LockService.BuildLockZonesData(worldData))
			print(`[BlockService] World Lock block placed at ({tileX}, {tileY}) by {player.Name}`)
			return true, "World locked! Break the gold block to unlock."
		elseif itemId == 27 then -- Small Lock (ID 27)
			-- Cannot place Small Lock if world is locked
			if LockService.IsWorldLocked(worldData) then
				return false, "World is locked — remove the world lock first!"
			end
			local success, message, claimedCount = LockService.PlaceSmallLock(player, worldData, tileX, tileY)
			if not success then
				return false, message
			end
			-- Place a silver foreground block as the visual representation of the small lock
			tile.fg = 27
			tile.hp = 15
			tile.bg = tile.bg or 0
			PlayerManager.RemoveItem(player, itemId, 1)
			worldData.updatedAt = os.time()
			-- Broadcast lock zone update so clients see the new claimed tiles
			PlayerManager.BroadcastToWorld(safeWorldName(worldData), "LockZonesUpdated", LockService.BuildLockZonesData(worldData))
			print(`[BlockService] Small Lock block placed at ({tileX}, {tileY}) by {player.Name} — claimed {claimedCount} tiles`)
			return true, "Small lock placed!"
		end
	end

	-- 14. Tall door check: must have empty tile above for 2-tile-high doors
	if itemDef.isTallDoor == true then
		if tileY - 1 < 0 then
			return false, "Not enough room for tall door (near top of world)"
		end
		local aboveIndex = tileX + (tileY - 1) * WorldConfig.WORLD_WIDTH + 1
		local aboveTile = worldData.tiles[aboveIndex]
		if not aboveTile then
			return false, "Upper tile out of bounds"
		end
		if aboveTile.fg ~= 0 and aboveTile.fg ~= nil then
			return false, "Upper tile is occupied (tall door needs 2 empty tiles)"
		end

		-- Place door in both tiles
		tile.fg = itemId
		tile.hp = itemDef.hp or 1
		aboveTile.fg = itemId
		aboveTile.hp = itemDef.hp or 1

		-- 15. Consume 1 item from inventory
		PlayerManager.RemoveItem(player, itemId, 1)
		worldData.updatedAt = os.time()

		print(`[BlockService] {player.Name} placed tall door {itemDef.name} at ({tileX}, {tileY}-{tileY-1})`)
		return true, "Tall door placed"
	end

	-- 15. Determine which layer to place the item in
	if itemDef.type == WorldConfig.ItemTypes.BACKGROUND then
		-- Background layer — check bg slot
		if tile.bg ~= 0 and tile.bg ~= nil then
			return false, "Background slot is occupied"
		end
		tile.bg = itemId
		tile.hp = itemDef.hp or 1
	else
		-- Foreground layer (SOLID, DOOR, SIGN, etc.)
		if tile.fg ~= 0 and tile.fg ~= nil then
			return false, "Foreground slot is occupied"
		end
		tile.fg = itemId
		tile.hp = itemDef.hp or 1
	end

	-- 16. Consume 1 item from inventory
	PlayerManager.RemoveItem(player, itemId, 1)

	worldData.updatedAt = os.time()

	print(`[BlockService] {player.Name} placed {itemDef.name} at ({tileX}, {tileY})`)
	return true, "Block placed"
end

--[[
	Initialize BlockService.
]]
function BlockService.Init()
	print("[BlockService] Initialized")
end

return BlockService
