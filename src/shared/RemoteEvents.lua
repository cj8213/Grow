-- RemoteEvents.lua (shared)
-- Central RemoteEvent/RemoteFunction definitions for GrowRoblox
-- All client-server communication goes through here
-- Works when require()d from both server and client without erroring
-- Server: creates instances in ReplicatedStorage if they don't exist
-- Client: fetches existing instances from ReplicatedStorage
--
-- Usage:
--   local Remotes = require(ReplicatedStorage.Shared.RemoteEvents)
--   -- Client fires:
--   Remotes.RequestBreakBlock:FireServer(tileX, tileY)
--   -- Server fires:
--   Remotes.TileUpdated:FireAllClients(worldName, tileX, tileY, tileData)
--   -- Server validates:
--   if not Remotes.Throttle(player, "RequestBreakBlock", 0.15) then return end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = {}
local IS_SERVER = RunService:IsServer()

-- Container folder for all remote instances
local REMOTES_FOLDER_NAME = "GrowRemotes"

-- Per-player per-event throttle state (server only)
-- throttleState[player.UserId][eventName] = lastFireTimestamp
local throttleState = {}

--[[
	Get or create a RemoteEvent in ReplicatedStorage.
	Server: creates the event if it doesn't exist.
	Client: fetches the event (errors if missing).
	
	@param name: string — the RemoteEvent name
	@return RemoteEvent
]]
local function GetOrCreateEvent(name: string): RemoteEvent
	local container = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
	if not container then
		if IS_SERVER then
			container = Instance.new("Folder")
			container.Name = REMOTES_FOLDER_NAME
			container.Parent = ReplicatedStorage
		else
			error("[RemoteEvents] Container folder 'GrowRemotes' not found in ReplicatedStorage")
		end
	end

	local existing = container:FindFirstChild(name)
	if existing then
		return existing :: RemoteEvent
	end

	if IS_SERVER then
		local event = Instance.new("RemoteEvent")
		event.Name = name
		event.Parent = container
		return event
	else
		error(("[RemoteEvents] RemoteEvent '%s' not found in GrowRemotes"):format(name))
	end
end

--[[
	Get or create a RemoteFunction in ReplicatedStorage.
	Server: creates the function if it doesn't exist.
	Client: fetches the function (errors if missing).
	
	@param name: string — the RemoteFunction name
	@return RemoteFunction
]]
local function GetOrCreateFunction(name: string): RemoteFunction
	local container = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
	if not container then
		if IS_SERVER then
			container = Instance.new("Folder")
			container.Name = REMOTES_FOLDER_NAME
			container.Parent = ReplicatedStorage
		else
			error("[RemoteEvents] Container folder 'GrowRemotes' not found in ReplicatedStorage")
		end
	end

	local existing = container:FindFirstChild(name)
	if existing then
		return existing :: RemoteFunction
	end

	if IS_SERVER then
		local func = Instance.new("RemoteFunction")
		func.Name = name
		func.Parent = container
		return func
	else
		error(("[RemoteEvents] RemoteFunction '%s' not found in GrowRemotes"):format(name))
	end
end

-- Create ALL remote instances upfront on the server
if IS_SERVER then
	-- Ensure container exists
	local container = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
	if not container then
		container = Instance.new("Folder")
		container.Name = REMOTES_FOLDER_NAME
		container.Parent = ReplicatedStorage
	end
end

--[[
	===== REMOTE EVENTS =====
]]

-- Client → Server: Player requests to break a block at (tileX, tileY)
-- Fires: (tileX: number, tileY: number)
Remotes.RequestBreakBlock = GetOrCreateEvent("RequestBreakBlock")

-- Client → Server: Player requests to place a block at (tileX, tileY) with itemId
-- Fires: (tileX: number, tileY: number, itemId: number)
Remotes.RequestPlaceBlock = GetOrCreateEvent("RequestPlaceBlock")

-- Client → Server: Player requests to plant a seed at (tileX, tileY)
-- Fires: (tileX: number, tileY: number, seedId: number)
Remotes.RequestPlantSeed = GetOrCreateEvent("RequestPlantSeed")

-- Client → Server: Player requests to harvest a tree at (tileX, tileY)
-- Fires: (tileX: number, tileY: number)
Remotes.RequestHarvestTree = GetOrCreateEvent("RequestHarvestTree")

-- Client → Server: Player requests to travel to another world
-- Fires: (worldName: string)
Remotes.RequestTravelWorld = GetOrCreateEvent("RequestTravelWorld")

-- Client → Server: Player requests to wrench a tile at (tileX, tileY)
-- Fires: (tileX: number, tileY: number)
Remotes.RequestWrenchTile = GetOrCreateEvent("RequestWrenchTile")

-- Client → Server: Player swaps inventory slots
-- Fires: (slotA: number, slotB: number)
Remotes.RequestSwapSlots = GetOrCreateEvent("RequestSwapSlots")

-- Client → Server: Player selects a hotbar slot as their equipped item
-- Fires: (slotIndex: number)
Remotes.RequestSetEquippedSlot = GetOrCreateEvent("RequestSetEquippedSlot")

-- Client → Server: Player chats in world
-- Fires: (message: string)
Remotes.RequestChatMessage = GetOrCreateEvent("RequestChatMessage")

-- Client → Server: Purchase an item from the store
-- Fires: (itemId: number, quantity: number)
Remotes.RequestPurchase = GetOrCreateEvent("RequestPurchase")

-- Client → Server: Set a door's destination world
-- Fires: (tileX: number, tileY: number, destinationWorldName: string)
Remotes.RequestSetDoorDestination = GetOrCreateEvent("RequestSetDoorDestination")

-- Client → Server: Add an admin to the world
-- Fires: (targetUserId: number)
Remotes.RequestAddAdmin = GetOrCreateEvent("RequestAddAdmin")

-- Client → Server: Remove an admin from the world
-- Fires: (targetUserId: number)
Remotes.RequestRemoveAdmin = GetOrCreateEvent("RequestRemoveAdmin")


-- Client → Server: Player requests to pick up a drop by its ID
-- Fires: (dropId: number)
Remotes.RequestPickupDrop = GetOrCreateEvent("RequestPickupDrop")

-- Server → Client: A new drop has been spawned
-- Fires: (dropEntry: table) — see DropService.SpawnDrop
Remotes.DropSpawned = GetOrCreateEvent("DropSpawned")

-- Server → Client: A drop has been destroyed (picked up or cleared)
-- Fires: (dropId: number)
Remotes.DropDestroyed = GetOrCreateEvent("DropDestroyed")

-- Server → Client: All drops for a world (sent on world enter after WorldLoaded)
-- Fires: (worldName: string, drops: table[])
Remotes.WorldDropsLoaded = GetOrCreateEvent("WorldDropsLoaded")

-- Server → Client: World data loaded, send full tile grid to player
-- Format: (worldName: string, tileData: { { i: number, fg: number?, bg: number?, hp: number?, owner: number?, treeData: table? } },
--          worldWidth: number, worldHeight: number)
Remotes.WorldLoaded = GetOrCreateEvent("WorldLoaded")

-- Server → Client: A single tile was updated (break, place, grow, etc.)
-- Fires: (worldName: string, tileX: number, tileY: number, tileData: table)
Remotes.TileUpdated = GetOrCreateEvent("TileUpdated")

-- Server → Client: Growth progress updates for multiple tiles
-- Format: (worldName: string, changedTiles: { { x: number, y: number, growthPercent: number } })
Remotes.GrowthUpdate = GetOrCreateEvent("GrowthUpdate")

-- Server → Client: Player's inventory was updated
-- Fires: (inventoryTable: { { itemId: number, count: number }? })
Remotes.InventoryUpdated = GetOrCreateEvent("InventoryUpdated")

-- Server → Client: Player's gem count was updated
-- Fires: (gemCount: number)
Remotes.GemsUpdated = GetOrCreateEvent("GemsUpdated")

-- Server → Client: Result of a splice attempt
-- Fires: (tileX: number, tileY: number, success: boolean, resultItemName: string?)
Remotes.SpliceResult = GetOrCreateEvent("SpliceResult")

-- Server → Client: A chat message to display
-- Fires: (senderName: string, message: string, color: Color3)
Remotes.ChatMessage = GetOrCreateEvent("ChatMessage")

-- Server → Client: World lock status change
-- Fires: (isLocked: boolean, ownerName: string?)
Remotes.WorldLockStatus = GetOrCreateEvent("WorldLockStatus")

-- Server → Client: Play a visual effect at a position
-- Fires: (effectType: string, tileX: number, tileY: number, itemId: number?)
Remotes.PlayEffect = GetOrCreateEvent("PlayEffect")

-- Server → Client: Wrench data for a tile (replaces old chat message response)
-- Fires: { tileX, tileY, fg, bg, treeData, lockInfo, isDoor, doorDestination }
Remotes.WrenchData = GetOrCreateEvent("WrenchData")

-- Server → Client: Store purchase result notification
-- Fires: (success: boolean, message: string)
Remotes.StoreResult = GetOrCreateEvent("StoreResult")

-- Server → Client: Player has spawned at a position in a world
-- Fires: (tileX: number, tileY: number, worldName: string)
Remotes.PlayerSpawned = GetOrCreateEvent("PlayerSpawned")

-- Server → Client: Show lock zone overlays (dev tool)
-- Fires: (worldLocked: boolean, lockOwner: number?, smallLockZones: { { x, y, width, height, owner } })
Remotes.ShowLockZones = GetOrCreateEvent("ShowLockZones")

-- Server → Client: Lock zone data updated (always sent on world enter + on lock change)
-- Format: table — see LockService.BuildLockZonesData()
-- Always broadcast so the client can render per-tile lock overlays automatically.
Remotes.LockZonesUpdated = GetOrCreateEvent("LockZonesUpdated")

-- Client → Server: Admin panel action request
-- Fires: (action: string, itemId: number?, count: number?)
Remotes.RequestAdminAction = GetOrCreateEvent("RequestAdminAction")

-- Client → Server: NPC interaction request (e.g. WAYFARER NPC)
-- Fires: (npcType: string, data: table)
Remotes.RequestNPCInteract = GetOrCreateEvent("RequestNPCInteract")

-- Server → Client: NPC interaction result
-- Fires: (npcType: string, data: table)
Remotes.NPCInteractResult = GetOrCreateEvent("NPCInteractResult")


--[[
	===== REMOTE FUNCTIONS =====
]]

-- Client → Server (request/response): Request full world data
-- Args: (worldName: string) → Returns: worldData table
Remotes.GetWorldData = GetOrCreateFunction("GetWorldData")

-- Client → Server (request/response): Request player inventory
-- Args: () → Returns: inventoryTable
Remotes.GetInventory = GetOrCreateFunction("GetInventory")

-- Client → Server (request/response): Request store catalog
-- Args: () → Returns: StoreCatalog[] table
Remotes.GetCatalog = GetOrCreateFunction("GetCatalog")

--[[
	===== THROTTLE HELPER =====
	
	Server-side only. Checks if the player is allowed to fire the given event.
	Returns true if the cooldown has passed, false if they're still on cooldown.
	Stores last-fire timestamps per player per event.
	
	@param player: Player — the player who fired the event
	@param eventName: string — name of the event (e.g., "RequestBreakBlock")
	@param cooldownSeconds: number — minimum seconds between fires (default: 0.15)
	@return boolean — true if allowed, false if throttled
]]
function Remotes.Throttle(player: Player, eventName: string, cooldownSeconds: number?): boolean
	if not IS_SERVER then
		return true -- Client doesn't throttle
	end

	local userId = player.UserId
	local cooldown = cooldownSeconds or 0.15
	local now = os.clock()

	-- Initialize throttle state for this player
	if not throttleState[userId] then
		throttleState[userId] = {}
	end

	local lastTime = throttleState[userId][eventName]
	if lastTime and (now - lastTime) < cooldown then
		return false -- Still on cooldown
	end

	-- Update timestamp
	throttleState[userId][eventName] = now
	return true
end

--[[
	Clean up throttle state when a player leaves (prevent memory leak)
]]
function Remotes.ClearThrottleForPlayer(player: Player)
	if IS_SERVER then
		throttleState[player.UserId] = nil
	end
end

--[[
	Clean up ALL throttle state (e.g., on game close)
]]
function Remotes.ClearAllThrottles()
	throttleState = {}
end

--[[
	Get a RemoteEvent by name (convenience).
	Useful for dynamic event access.
]]
function Remotes.GetEvent(name: string): RemoteEvent?
	local container = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
	if not container then return nil end
	local event = container:FindFirstChild(name)
	if event and event:IsA("RemoteEvent") then
		return event :: RemoteEvent
	end
	return nil
end

--[[
	Get a RemoteFunction by name (convenience).
]]
function Remotes.GetFunction(name: string): RemoteFunction?
	local container = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
	if not container then return nil end
	local func = container:FindFirstChild(name)
	if func and func:IsA("RemoteFunction") then
		return func :: RemoteFunction
	end
	return nil
end

-- Log initialization
if IS_SERVER then
	print("[RemoteEvents] Initialized on SERVER — all remotes created in " .. REMOTES_FOLDER_NAME)
else
	print("[RemoteEvents] Initialized on CLIENT — fetching remotes from " .. REMOTES_FOLDER_NAME)
end

return Remotes
