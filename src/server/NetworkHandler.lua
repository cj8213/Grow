--!strict
-- NetworkHandler.lua (Task #8)
-- Central server-side handler for all client RemoteEvent requests.
-- Bridges PlayerManager (world tracking) with existing services (Block/Seed/etc.)
-- Validates every incoming request: throttle → reach → lock → delegate
--
-- Architecture:
--   NetworkHandler.Init() wires all client→server RemoteEvents
--   Each handler: throttle → validate → delegate to service → broadcast via PlayerManager
--   Does NOT duplicate inventory/gem logic already in services.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = require(ReplicatedStorage.Shared)
local RemoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)
local ItemDatabase = Shared.ItemDatabase
local WorldConfig = Shared.WorldConfig

local PlayerManager = require(script.Parent.PlayerManager)
local WorldService = require(script.Parent.WorldService)
local BlockService = require(script.Parent.BlockService)
local LockService = require(script.Parent.LockService)
local SeedService = require(script.Parent.SeedService)
local InventoryService = require(script.Parent.InventoryService)
local GemService = require(script.Parent.GemService)
local StoreService = require(script.Parent.StoreService)
local DevTools = require(script.Parent.DevTools)

local NetworkHandler = {}

--[[
	===== VALIDATION HELPERS =====
]]

--[[
	Get the player's current world name and data.
]]
local function getPlayerWorld(player: Player): (string?, table?)
	local worldName = PlayerManager.GetPlayerWorld(player)
	if not worldName then return nil, nil end

	local allWorlds = WorldService.GetAllWorlds()
	if not allWorlds then return nil, nil end

	return worldName, allWorlds[worldName]
end

--[[
	Validate tile coordinates are within world bounds.
]]
local function isValidTile(x: any, y: any): boolean
	if type(x) ~= "number" or type(y) ~= "number" then
		return false
	end
	return x >= 0 and x < WorldConfig.WORLD_WIDTH
		and y >= 0 and y < WorldConfig.WORLD_HEIGHT
end

--[[
	Get distance from player to a tile (uses character position).
]]
local function getPlayerReach(player: Player, tileX: number, tileY: number): number
	local char = player.Character
	if char then
		local root = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso")
		if root then
			local pos = root.Position
			-- Convert world position to tile coordinates
			-- X: tile 0 starts at world position 0, tile center = tileX * TILE_SIZE
			-- Y: tile 0 is at the top, world Y increases upward, tile center = -tileY * TILE_SIZE
			local playerTileX = math.floor(pos.X / WorldConfig.TILE_SIZE + 0.5)
			local playerTileY = math.floor(-pos.Y / WorldConfig.TILE_SIZE + 0.5)
			return math.max(math.abs(playerTileX - tileX), math.abs(playerTileY - tileY))
		end
	end
	return 0
end

--[[
	===== REQUEST HANDLERS =====
	Each handler follows this pattern:
	1) Throttle check (reject if too fast)
	2) Validate inputs (type checks, bounds)
	3) Get player's current world
	4) Check lock access (via LockService)
	5) Check reach
	6) Check inventory (via InventoryService)
	7) Delegate to service
	8) Broadcast updates
]]

--[[
	Break a block at (tileX, tileY).
	BlockService handles all validation + drops automatically.
]]
local function onRequestBreakBlock(player: Player, tileX: number, tileY: number)
	if not RemoteEvents.Throttle(player, "RequestBreakBlock", 0.2) then
		return
	end

	if not isValidTile(tileX, tileY) then
		return
	end

	local worldName, worldData = getPlayerWorld(player)
	if not worldData then
		return
	end

	-- Lock check
	if not LockService.CanModify(player, worldData, tileX, tileY) then
		return
	end

	-- Delegate to BlockService (it validates reach, inventory, does drops)
	local success, drops = BlockService.BreakBlock(player, worldData, tileX, tileY)

	if success then
		-- Get updated tile state
		local tile = WorldService.GetTile(worldName, tileX, tileY)
		if tile then
			-- Broadcast tile update to all players in world
			PlayerManager.BroadcastToWorld(worldName, "TileUpdated", worldName, tileX, tileY, {
				fg = tile.fg,
				bg = tile.bg,
				hp = tile.hp,
				treeData = tile.treeData,
			})
		end
	end
end

--[[
	Place a block at (tileX, tileY) with a specific itemId.
	BlockService handles all validation + consumptions automatically.
]]
local function onRequestPlaceBlock(player: Player, tileX: number, tileY: number, itemId: number)
	if not RemoteEvents.Throttle(player, "RequestPlaceBlock", 0.3) then
		return
	end
	if not isValidTile(tileX, tileY) then
		return
	end
	if type(itemId) ~= "number" or itemId <= 0 then
		return
	end

	local worldName, worldData = getPlayerWorld(player)
	if not worldData then
		return
	end

	-- Lock check
	if not LockService.CanModify(player, worldData, tileX, tileY) then
		return
	end

	-- Delegate to BlockService (validates reach, inventory, handles locks, does placement)
	local success, message = BlockService.PlaceBlock(player, worldData, tileX, tileY, itemId)
	if success then
		local tile = WorldService.GetTile(worldName, tileX, tileY)
		if tile then
			PlayerManager.BroadcastToWorld(worldName, "TileUpdated", worldName, tileX, tileY, {
				fg = tile.fg,
				bg = tile.bg,
				hp = tile.hp,
				treeData = tile.treeData,
			})
		end

		PlayerManager.FireToPlayer(player, "InventoryUpdated", InventoryService.GetInventory(player))
	end
end

--[[
	Plant a seed at (tileX, tileY).
	SeedService.PlantSeed handles ALL validation + seed consumption internally.
	This handler just does basic throttle + lock check + broadcasts.
]]
local function onRequestPlantSeed(player: Player, tileX: number, tileY: number, seedId: number)
	if not RemoteEvents.Throttle(player, "RequestPlantSeed", 0.5) then return end
	if not isValidTile(tileX, tileY) then return end
	if type(seedId) ~= "number" or seedId <= 0 then return end

	local worldName, worldData = getPlayerWorld(player)
	if not worldData then return end

	if not LockService.CanModify(player, worldData, tileX, tileY) then
		return
	end

	-- Delegate to SeedService (handles reach, fg-empty, below-solid, inventory check, consumption, splice)
	local success, message = SeedService.PlantSeed(player, worldData, tileX, tileY, seedId)
	if success then
		local tile = WorldService.GetTile(worldName, tileX, tileY)
		if tile then
			PlayerManager.BroadcastToWorld(worldName, "TileUpdated", worldName, tileX, tileY, {
				fg = tile.fg,
				bg = tile.bg,
				hp = tile.hp,
				treeData = tile.treeData,
			})
		end

		PlayerManager.FireToPlayer(player, "InventoryUpdated", InventoryService.GetInventory(player))
	else
		PlayerManager.FireToPlayer(player, "ChatMessage", "", message or "Cannot plant here", Color3.fromRGB(255, 200, 100))
	end
end

--[[
	Harvest a fully grown tree at (tileX, tileY).
	SeedService handles all drop logic already.
]]
local function onRequestHarvestTree(player: Player, tileX: number, tileY: number)
	if not RemoteEvents.Throttle(player, "RequestHarvestTree", 0.5) then return end
	if not isValidTile(tileX, tileY) then return end

	local worldName, worldData = getPlayerWorld(player)
	if not worldData then return end

	if not LockService.CanModify(player, worldData, tileX, tileY) then
		return
	end

	-- Delegate to SeedService (handles reach, growth check, drops internally)
	local success = SeedService.HarvestTree(player, worldData, tileX, tileY)
	if success then
		local tile = WorldService.GetTile(worldName, tileX, tileY)
		if tile then
			PlayerManager.BroadcastToWorld(worldName, "TileUpdated", worldName, tileX, tileY, {
				fg = tile.fg,
				bg = tile.bg,
				hp = tile.hp,
				treeData = nil,
			})
		end
		PlayerManager.FireToPlayer(player, "SpliceResult", tileX, tileY, true, "Harvested!")
	else
		PlayerManager.FireToPlayer(player, "SpliceResult", tileX, tileY, false, "Tree not ready")
	end
end

--[[
	Travel to another world.
	PlayerManager.MovePlayerToWorld handles all load/generation/broadcasting.
]]
local function onRequestTravelWorld(player: Player, worldName: string)
	if not RemoteEvents.Throttle(player, "RequestTravelWorld", 1.0) then return end
	if type(worldName) ~= "string" or #worldName == 0 then return end

	PlayerManager.MovePlayerToWorld(player, worldName)
end

--[[
	Wrench a tile — inspect its properties.
	Sends structured WrenchData to the player for the WrenchUI to display.
]]
local function onRequestWrenchTile(player: Player, tileX: number, tileY: number)
	if not RemoteEvents.Throttle(player, "RequestWrenchTile", 0.5) then return end
	if not isValidTile(tileX, tileY) then return end

	local worldName = PlayerManager.GetPlayerWorld(player)
	if not worldName then return end

	local tile = WorldService.GetTile(worldName, tileX, tileY)
	if not tile then return end

	-- Get world lock info
	local worldData = WorldService.GetAllWorlds()[worldName]
	local lockOwnerId = worldData and worldData.lockOwner or nil
	local admins = worldData and worldData.admins or {}

	-- Determine if tile is a door or portal
	local isDoor = false
	local isMainDoor = false
	local doorDestination = nil
	if tile.fg and tile.fg > 0 then
		local fgItemDef = ItemDatabase.GetItem(tile.fg)
		if fgItemDef then
			local itemType = fgItemDef.type
			isDoor = (itemType == WorldConfig.ItemTypes.DOOR or itemType == WorldConfig.ItemTypes.PORTAL)
			if isDoor and tile.fgExtra and tile.fgExtra.doorDestination then
				doorDestination = tile.fgExtra.doorDestination
			end
			-- Main Door (itemId 6) always shows "START"
			if tile.fg == 6 then
				isMainDoor = true
				doorDestination = "START"
			end
		end
	end

	-- Determine tree growth info
	local treeInfo = nil
	if tile.treeData then
		local elapsed = os.time() - (tile.treeData.plantedAt or os.time())
		local growthTime = tile.treeData.growthTime or 60
		local growthPercent = math.min(100, math.floor((elapsed / growthTime) * 100))
		treeInfo = {
			seedId = tile.treeData.seedId,
			growthPercent = growthPercent,
		}
	end

	-- Build lock info
	local lockInfo = nil
	if lockOwnerId then
		lockInfo = {
			isLocked = true,
			ownerUserId = lockOwnerId,
			admins = admins,
			isOwner = (player.UserId == lockOwnerId),
		}
	end

	-- Fire structured WrenchData to the requesting player
	PlayerManager.FireToPlayer(player, "WrenchData", {
		tileX = tileX,
		tileY = tileY,
		fg = tile.fg,
		bg = tile.bg,
		hp = tile.hp,
		isDoor = isDoor,
		isMainDoor = isMainDoor,
		doorDestination = doorDestination,
		treeInfo = treeInfo,
		lockInfo = lockInfo,
	})
end

--[[
	Swap two inventory slots.
]]
local function onRequestSwapSlots(player: Player, slotA: number, slotB: number)
	if not RemoteEvents.Throttle(player, "RequestSwapSlots", 0.1) then return end
	if type(slotA) ~= "number" or type(slotB) ~= "number" then return end

	InventoryService.SwapSlots(player, slotA, slotB)
	PlayerManager.FireToPlayer(player, "InventoryUpdated", InventoryService.GetInventory(player))
end

--[[
	Set the equipped hotbar slot.
]]
local function onRequestSetEquippedSlot(player: Player, slotIndex: number)
	if not RemoteEvents.Throttle(player, "RequestSetEquippedSlot", 0.05) then return end
	if type(slotIndex) ~= "number" or slotIndex < 0 or slotIndex >= WorldConfig.HOTBAR_SLOTS then
		return
	end

	InventoryService.SetEquippedSlot(player, slotIndex)
end

--[[
	Handle chat messages from the client.
	Broadcasts to all players in the same world, or handles commands.
]]
local function onRequestChatMessage(player: Player, message: string)
	if not RemoteEvents.Throttle(player, "RequestChatMessage", 0.5) then return end
	if type(message) ~= "string" or #message == 0 or #message > 200 then return end

	-- Handle slash commands (use ; as prefix since / is consumed by chat UI)
	if string.sub(message, 1, 1) == ";" then
		local parts = string.split(message, " ")
		local cmd = string.lower(parts[1])

		-- Check DevTools commands first (Studio-only: godmode, printworld, tp, showlocks)
		if DevTools.HandleCommand(player, string.sub(cmd, 2), parts) then
			return
		end

		if cmd == ";help" then
			PlayerManager.FireToPlayer(player, "ChatMessage", "System",
				"Commands: ;help, ;clear, ;give <itemId> [count], ;warp <world>, ;showlocks", Color3.fromRGB(200, 200, 255))
			PlayerManager.FireToPlayer(player, "ChatMessage", "System",
				"  ;give 26 1 = World Lock, ;give 27 1 = Small Lock", Color3.fromRGB(200, 200, 255))
			PlayerManager.FireToPlayer(player, "ChatMessage", "System",
				"  ;give 101 = Dirt Seed, ;give 102 = Rock Seed", Color3.fromRGB(200, 200, 255))

		elseif cmd == ";clear" then
			-- Clear inventory (dev utility)
			InventoryService.ClearInventory(player)
			PlayerManager.FireToPlayer(player, "InventoryUpdated", InventoryService.GetInventory(player))
			PlayerManager.FireToPlayer(player, "ChatMessage", "System", "Inventory cleared!", Color3.fromRGB(200, 255, 200))

		elseif cmd == ";give" then
			-- Give item: ;give <itemId> [count]
			local itemId = tonumber(parts[2])
			local count = tonumber(parts[3]) or 1
			print(`[DEBUG cmd] {player.Name} requested: itemId={itemId}, count={count}, parts={#parts}`)
			if itemId and itemId > 0 and count > 0 then
				local addOk, addOverflow = InventoryService.AddItem(player, itemId, count)
				print(`[DEBUG cmd] AddItem result: ok={addOk}, overflow={addOverflow}`)
				local finalInv = InventoryService.GetInventory(player)
				PlayerManager.FireToPlayer(player, "InventoryUpdated", finalInv)
				PlayerManager.FireToPlayer(player, "ChatMessage", "System",
					`Gave {count}x item #{itemId}`, Color3.fromRGB(200, 255, 200))
			else
				PlayerManager.FireToPlayer(player, "ChatMessage", "System",
					`Usage: ;give <itemId> [count] (got "{tostring(parts[2])}" = {tostring(itemId)})`, Color3.fromRGB(255, 200, 200))
			end

		elseif cmd == ";world" or cmd == ";warp" then
			-- Travel to another world: ;warp <worldname>
			local targetWorld = parts[2]
			if targetWorld then
				PlayerManager.MovePlayerToWorld(player, targetWorld)
			else
				PlayerManager.FireToPlayer(player, "ChatMessage", "System",
					"Usage: ;warp <worldname>", Color3.fromRGB(255, 200, 200))
			end

		else
			PlayerManager.FireToPlayer(player, "ChatMessage", "System",
				`Unknown command: {cmd} — type ;help`, Color3.fromRGB(255, 200, 200))
		end
		return
	end

	-- Broadcast chat message to all players in current world
	local worldName = PlayerManager.GetPlayerWorld(player)
	if worldName then
		PlayerManager.BroadcastToWorld(worldName, "ChatMessage", player.Name, message, Color3.fromRGB(255, 255, 255))
	end
	print(`[DEBUG /give] {player.Name} sent chat: "{message}" (not a command, broadcasting)`)
end

--[[
	Purchase an item from the store.
	Delegates to StoreService.Purchase which handles atomic gem/inventory logic.
	StoreService fires InventoryUpdated + GemsUpdated + StoreResult on success.
]]
local function onRequestPurchase(player: Player, itemId: number, quantity: number)
	if not RemoteEvents.Throttle(player, "RequestPurchase", 1.0) then return end
	if type(itemId) ~= "number" or itemId <= 0 then
		PlayerManager.FireToPlayer(player, "StoreResult", false, "Invalid item")
		return
	end
	if type(quantity) ~= "number" or quantity < 1 or quantity > 99 then
		PlayerManager.FireToPlayer(player, "StoreResult", false, "Invalid quantity (1–99)")
		return
	end

	StoreService.Purchase(player, itemId, quantity)
	-- StoreService handles all inventory/gems/StoreResult firing internally
end

--[[
	Set a door tile's destination world.
	Only the world lock owner can set door destinations.
	Main Door (itemId 6) is always locked to "START".
]]
local function onRequestSetDoorDestination(player: Player, tileX: number, tileY: number, destinationWorldName: string)
	if not RemoteEvents.Throttle(player, "RequestSetDoorDestination", 0.5) then return end
	if not isValidTile(tileX, tileY) then return end
	if type(destinationWorldName) ~= "string" or #destinationWorldName == 0 then return end

	local worldName, worldData = getPlayerWorld(player)
	if not worldData then return end

	-- Validate the tile is a door
	local tile = WorldService.GetTile(worldName, tileX, tileY)
	if not tile or not tile.fg or tile.fg <= 0 then return end
	local fgItem = ItemDatabase.GetItem(tile.fg)
	if not fgItem then return end
	local itemType = fgItem.type
	if itemType ~= WorldConfig.ItemTypes.DOOR and itemType ~= WorldConfig.ItemTypes.PORTAL then
		return
	end

	-- Main Door (itemId 6) cannot be re-targeted
	if tile.fg == 6 then return end

	-- Only world lock owner can set door destinations
	if not worldData.lockOwner or worldData.lockOwner ~= player.UserId then
		PlayerManager.FireToPlayer(player, "ChatMessage", "System",
			"Only the world owner can set door destinations!", Color3.fromRGB(255, 200, 200))
		return
	end

	-- Normalize destination world name
	local normalizedDest = string.upper(string.gsub(destinationWorldName, "[^%w_]", ""))
	if #normalizedDest == 0 then
		PlayerManager.FireToPlayer(player, "ChatMessage", "System",
			"Invalid world name!", Color3.fromRGB(255, 200, 200))
		return
	end
	if #normalizedDest > 20 then
		normalizedDest = string.sub(normalizedDest, 1, 20)
	end

	-- Store door destination in tile.fgExtra
	tile.fgExtra = tile.fgExtra or {}
	tile.fgExtra.doorDestination = normalizedDest

	-- Broadcast tile update
	PlayerManager.BroadcastToWorld(worldName, "TileUpdated", worldName, tileX, tileY, {
		fg = tile.fg,
		bg = tile.bg,
		hp = tile.hp,
		treeData = tile.treeData,
	})

	PlayerManager.FireToPlayer(player, "ChatMessage", "System",
		`Door destination set to "{normalizedDest}"`, Color3.fromRGB(200, 255, 200))
	print(`[NetworkHandler] {player.Name} set door at ({tileX},{tileY}) in "{worldName}" → "{normalizedDest}"`)
end

--[[
	Add an admin to this world.
	Only the world lock owner can add admins.
]]
local function onRequestAddAdmin(player: Player, targetUserId: number)
	if not RemoteEvents.Throttle(player, "RequestAddAdmin", 1.0) then return end
	if type(targetUserId) ~= "number" or targetUserId <= 0 then return end

	local worldName, worldData = getPlayerWorld(player)
	if not worldData then return end

	local success = LockService.AddAdmin(player, targetUserId, worldData)
	if success then
		-- Broadcast updated lock status to all players in world
		PlayerManager.BroadcastToWorld(worldName, "WorldLockStatus", true, player.Name)
		PlayerManager.FireToPlayer(player, "ChatMessage", "System",
			`Added userId={targetUserId} as admin`, Color3.fromRGB(200, 255, 200))
		print(`[NetworkHandler] {player.Name} added admin userId={targetUserId} in "{worldName}"`)
	else
		PlayerManager.FireToPlayer(player, "ChatMessage", "System",
			"Failed to add admin. Are you the world owner?", Color3.fromRGB(255, 200, 200))
	end
end

--[[
	Remove an admin from this world.
	Only the world lock owner can remove admins.
]]
local function onRequestRemoveAdmin(player: Player, targetUserId: number)
	if not RemoteEvents.Throttle(player, "RequestRemoveAdmin", 1.0) then return end
	if type(targetUserId) ~= "number" or targetUserId <= 0 then return end

	local worldName, worldData = getPlayerWorld(player)
	if not worldData then return end

	local success = LockService.RemoveAdmin(player, targetUserId, worldData)
	if success then
		PlayerManager.BroadcastToWorld(worldName, "WorldLockStatus", true, player.Name)
		PlayerManager.FireToPlayer(player, "ChatMessage", "System",
			`Removed userId={targetUserId} from admins`, Color3.fromRGB(200, 255, 200))
		print(`[NetworkHandler] {player.Name} removed admin userId={targetUserId} in "{worldName}"`)
	else
		PlayerManager.FireToPlayer(player, "ChatMessage", "System",
			"Failed to remove admin. Are you the world owner?", Color3.fromRGB(255, 200, 200))
	end
end

--[[
	===== INIT =====
]]

--[[
	Initialize NetworkHandler.
	Wires all client→server RemoteEvents. Must be called after all services.
]]
function NetworkHandler.Init()
	-- Client → Server action requests
	RemoteEvents.RequestBreakBlock.OnServerEvent:Connect(onRequestBreakBlock)
	RemoteEvents.RequestPlaceBlock.OnServerEvent:Connect(onRequestPlaceBlock)
	RemoteEvents.RequestPlantSeed.OnServerEvent:Connect(onRequestPlantSeed)
	RemoteEvents.RequestHarvestTree.OnServerEvent:Connect(onRequestHarvestTree)
	RemoteEvents.RequestTravelWorld.OnServerEvent:Connect(onRequestTravelWorld)
	RemoteEvents.RequestWrenchTile.OnServerEvent:Connect(onRequestWrenchTile)
	RemoteEvents.RequestSwapSlots.OnServerEvent:Connect(onRequestSwapSlots)
	RemoteEvents.RequestSetEquippedSlot.OnServerEvent:Connect(onRequestSetEquippedSlot)
	RemoteEvents.RequestChatMessage.OnServerEvent:Connect(onRequestChatMessage)
	RemoteEvents.RequestPurchase.OnServerEvent:Connect(onRequestPurchase)
	RemoteEvents.RequestSetDoorDestination.OnServerEvent:Connect(onRequestSetDoorDestination)
	RemoteEvents.RequestAddAdmin.OnServerEvent:Connect(onRequestAddAdmin)
	RemoteEvents.RequestRemoveAdmin.OnServerEvent:Connect(onRequestRemoveAdmin)

	-- Client → Server: NPC interaction (WAYFARER etc.)
	RemoteEvents.RequestNPCInteract.OnServerEvent:Connect(function(player: Player, npcType: string, data: table)
		print(`[NetworkHandler] NPC interact: {player.Name}, type={npcType}`)
		if npcType == "WAYFARER" then
			-- Open world entry UI on client — stub for future NPC interaction
			RemoteEvents.NPCInteractResult:FireClient(player, "WAYFARER", {})
		end
	end)

	-- Client → Server: Admin panel actions
	RemoteEvents.RequestAdminAction.OnServerEvent:Connect(function(player: Player, action: string, itemId: number?, count: number?)
		if type(action) ~= "string" then return end
		if not RunService:IsStudio() then return end -- Studio only

		if action == "give" and itemId and itemId > 0 then
			local c = count or 1
			InventoryService.AddItem(player, itemId, c)
			local inv = InventoryService.GetInventory(player)
			PlayerManager.FireToPlayer(player, "InventoryUpdated", inv)
		elseif action == "clear" then
			InventoryService.ClearInventory(player)
			local inv = InventoryService.GetInventory(player)
			PlayerManager.FireToPlayer(player, "InventoryUpdated", inv)
		elseif action == "showlocks" then
			local worldName = PlayerManager.GetPlayerWorld(player)
			if worldName then
				local wd = WorldService.GetCachedWorld(worldName)
				if wd then
					local lockData = LockService.BuildLockZonesData(wd)
					PlayerManager.FireToPlayer(player, "LockZonesUpdated", lockData)
				end
			end
		elseif action == "removelocks" then
			-- Remove ALL locks from the current world (World Lock + Small Locks)
			local worldName = PlayerManager.GetPlayerWorld(player)
			if worldName then
				local wd = WorldService.GetCachedWorld(worldName)
				if wd then
					local locksReturned = 0
					-- Scan all tiles for lock blocks (fg=26 or fg=27)
					if wd.tiles then
						for _, tile in ipairs(wd.tiles) do
							if tile.fg == 26 then
								tile.fg = 0
								tile.bg = tile.bg or 0
								tile.hp = 0
								locksReturned += 1
							elseif tile.fg == 27 then
								tile.fg = 0
								tile.bg = tile.bg or 0
								tile.hp = 0
								locksReturned += 1
							end
						end
					end
					-- Clear world lock
					local hadWorldLock = wd.lockOwner ~= nil
					wd.lockOwner = nil
					wd.admins = {}
					-- Clear all small locks using new dynamic lock system
					local smallLocksRemoved, smallLockItems = LockService.RemoveAllLocks(wd)
					-- Return locks to inventory
					local totalLockItems = locksReturned + smallLockItems
					if totalLockItems > 0 then
						PlayerManager.AddItem(player, 26, locksReturned)
						if smallLockItems > 0 then
							PlayerManager.AddItem(player, 27, smallLockItems)
						end
					end
					if hadWorldLock then
						PlayerManager.BroadcastToWorld(worldName, "WorldLockStatus", false, nil)
					end
					wd.updatedAt = os.time()
					PlayerManager.FireToPlayer(player, "ChatMessage", "System",
						`Removed {locksReturned} lock block(s) + {smallLocksRemoved} small lock zone(s)`, Color3.fromRGB(200, 255, 200))
					local InventoryService = require(script.Parent.InventoryService)
					PlayerManager.FireToPlayer(player, "InventoryUpdated", InventoryService.GetInventory(player))
					-- Broadcast updated lock visualization
					PlayerManager.BroadcastToWorld(worldName, "LockZonesUpdated", LockService.BuildLockZonesData(wd))
					print(`[Admin] Removed all locks from "{worldName}" by {player.Name}`)
				end
			end
		elseif action == "cleardrops" then
			local worldName = PlayerManager.GetPlayerWorld(player)
			if worldName then
				local wd = WorldService.GetCachedWorld(worldName)
				if wd then
					-- Clear server-side drop Parts and folder
					DropService.ClearWorldDrops(worldName)
					-- Clear the worldData.drops array so persisted data is gone
					local dropCount = 0
					if wd.drops then
						dropCount = #wd.drops
						wd.drops = {}
					end
					wd.updatedAt = os.time()
					PlayerManager.FireToPlayer(player, "ChatMessage", "System",
						`Cleared {dropCount} drops from "{worldName}"`, Color3.fromRGB(200, 255, 200))
					print(`[Admin] {player.Name} cleared all drops from "{worldName}" ({dropCount} drops)`)
				end
			end
		end
	end)

	-- Client → Server RemoteFunction invocations
	RemoteEvents.GetWorldData.OnServerInvoke = function(player: Player, worldName: string): table?
		if type(worldName) ~= "string" or #worldName == 0 then return nil end
		local data = WorldService.GetOrCreateWorld(worldName)
		if not data then return nil end
		-- Return a safe copy (avoid sending full tile array over function)
		return {
			name = data.name,
			lockOwner = data.lockOwner,
			admins = data.admins,
		}
	end

	RemoteEvents.GetInventory.OnServerInvoke = function(player: Player): { { itemId: number, count: number }? }
		return InventoryService.GetInventory(player)
	end

	RemoteEvents.GetCatalog.OnServerInvoke = function(_player: Player): { table }
		return StoreService.GetCatalog()
	end

	print("[NetworkHandler] Initialized — all remote events wired with validation (Store + Door + Admin)")
end

return NetworkHandler
