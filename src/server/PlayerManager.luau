--!strict
-- PlayerManager.luau (rewrite for Task #8)
-- Multiplayer world tracking, BroadcastToWorld, MovePlayerToWorld
-- Tracks every player's current world, handles join/leave/teleport
-- Single broadcast function for all world-scoped remote events
--
-- Usage:
--   PlayerManager.MovePlayerToWorld(player, "MYWORLD")
--   PlayerManager.BroadcastToWorld("MYWORLD", "TileUpdated", tileX, tileY, tileData)
--   PlayerManager.GetPlayersInWorld("MYWORLD") -> { Player }

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)
local WorldConfig = require(ReplicatedStorage.Shared.WorldConfig)
local WorldService = require(script.Parent.WorldService)
local InventoryService = require(script.Parent.InventoryService)
local GemService = require(script.Parent.GemService)
local DataService = require(script.Parent.DataService)
local ProfileStore = require(script.Parent.ProfileStore)

-- Studs per tile (must match client: InputController.lua, WorldRenderer.lua, CameraController.lua)
local TILE_SIZE = 4

local PlayerManager = {}

--[[
	===== STATE =====
]]

-- playerWorld[userId] = worldName (the world the player is currently in)
local playerWorld: { [number]: string } = {}

-- pendingUnloads[worldName] = { task: thread|table, worldName: string }
-- Used to track worlds scheduled for unload
local pendingUnloads: { [string]: { cancel: () -> () } } = {}

-- The START world — special, never unloaded, generated once on boot
local START_WORLD_NAME = "START"

--[[
	===== WORLD TRACKING =====
]]

--[[
	Get the world a player is currently in.
	@param player: Player
	@return string? — world name or nil if not tracked
]]
function PlayerManager.GetPlayerWorld(player: Player): string?
	return playerWorld[player.UserId]
end

--[[
	Get all players currently in a given world.
	@param worldName: string — the world name
	@return { Player } — array of players
]]
function PlayerManager.GetPlayersInWorld(worldName: string): { Player }
	local result: { Player } = {}
	local upperName = string.upper(worldName)

	for _, player in ipairs(Players:GetPlayers()) do
		if playerWorld[player.UserId] == upperName then
			table.insert(result, player)
		end
	end

	return result
end

--[[
	Check if a world has any players in it.
	@param worldName: string
	@return boolean
]]
function PlayerManager.WorldHasPlayers(worldName: string): boolean
	return #PlayerManager.GetPlayersInWorld(worldName) > 0
end

--[[
	Get all currently active world names (worlds with tracking data).
	@return { string }
]]
function PlayerManager.GetAllActiveWorlds(): { string }
	local worlds: { [string]: boolean } = {}
	for _, name in pairs(playerWorld) do
		worlds[name] = true
	end

	local result: { string } = {}
	for name in pairs(worlds) do
		table.insert(result, name)
	end

	return result
end

--[[
	===== BROADCAST TO WORLD =====
	The ONLY function that iterates players to fire RemoteEvents.
	All services must use this instead of :FireAllClients().
]]

--[[
	Broadcast a remote event to all players in a world.
	@param worldName: string — world name (case-insensitive)
	@param remoteName: string — the RemoteEvent field name on the RemoteEvents module
		(e.g. "TileUpdated", "GrowthUpdate", "ChatMessage")
	@param ...: any — arguments to pass to FireClient
]]
function PlayerManager.BroadcastToWorld(worldName: string, remoteName: string, ...: any)
	local upperName = string.upper(worldName)
	local remote = RemoteEvents[remoteName]
	if not remote or not remote:IsA("RemoteEvent") then
		warn(`[PlayerManager] BroadcastToWorld: unknown remote "{remoteName}" or not a RemoteEvent`)
		return
	end

	local players = PlayerManager.GetPlayersInWorld(upperName)
	for _, player in ipairs(players) do
		remote:FireClient(player, ...)
	end
end

--[[
	Fire a remote event to a specific player (player-scoped update).
	Convenience wrapper.
	@param player: Player
	@param remoteName: string — field name on RemoteEvents module
	@param ...: any — arguments
]]
function PlayerManager.FireToPlayer(player: Player, remoteName: string, ...: any)
	local remote = RemoteEvents[remoteName]
	if not remote or not remote:IsA("RemoteEvent") then
		warn(`[PlayerManager] FireToPlayer: unknown remote "{remoteName}"`)
		return
	end
	remote:FireClient(player, ...)
end

--[[
	===== WORLD TRAVEL =====
]]

--[[
	Validate a world name: alphanumeric + underscore, max 20 chars, not empty.
	@param worldName: string
	@return string? — normalized name or nil if invalid
]]
local function validateWorldName(worldName: string): string?
	local normalized = string.upper(string.gsub(worldName, "[^%w_]", ""))

	if #normalized == 0 then return nil end
	if #normalized > 20 then
		normalized = string.sub(normalized, 1, 20)
	end

	return normalized
end

--[[
	Move a player to a different world.
	
	Steps:
	1. Validate world name
	2. Save current world data if they were in one
	3. Cancel pending unload for the destination world (if any)
	4. Load or generate the destination world via WorldService
	5. Broadcast leave message to old world players
	6. Fire WorldLoaded to the player
	7. Fire WorldLockStatus, GemsUpdated, InventoryUpdated to player
	8. Broadcast enter message to new world players
	9. Update playerWorld[userId]
	
	@param player: Player
	@param worldName: string — destination world name
	@return boolean, string — success and message
]]
function PlayerManager.MovePlayerToWorld(player: Player, worldName: string): (boolean, string)
	-- 1. Validate
	if not player or not player.UserId then
		return false, "Invalid player"
	end

	local normalized = validateWorldName(worldName)
	if not normalized then
		return false, "Invalid world name (use letters, numbers, underscores; max 20 chars)"
	end

	-- 2. Get the old world name
	local oldWorld = playerWorld[player.UserId]

	-- 3. Cancel any pending unload for destination world (someone's entering it)
	PlayerManager.CancelWorldUnload(normalized)

	-- 4. Load/generate the destination world
	local worldData: table?
	local success, result = pcall(function()
		return WorldService.GetOrCreateWorld(normalized)
	end)

	if not success or not result then
		warn(`[PlayerManager] Failed to load world "{normalized}": {result}`)
		-- Fallback: send player to START
		if normalized ~= START_WORLD_NAME then
			return PlayerManager.MovePlayerToWorld(player, START_WORLD_NAME)
		end
		return false, "Failed to load world"
	end

	worldData = result

	-- 5. Broadcast leave message to old world
	if oldWorld and oldWorld ~= normalized then
		local systemColor = Color3.fromRGB(180, 180, 180)
		PlayerManager.BroadcastToWorld(oldWorld, "ChatMessage", "", `← {player.Name} left the world`, systemColor)
	end

	-- 6. Send WorldLoaded to player with sparse tile data
	-- Build sparse tile data (only non-default tiles for efficient transfer)
	local sparseTiles = WorldService.BuildSparseTileData(worldData)
	PlayerManager.FireToPlayer(player, "WorldLoaded", normalized, sparseTiles, WorldService.WORLD_WIDTH, WorldService.WORLD_HEIGHT)

	-- 7. Send WorldLockStatus
	local isLocked = worldData.lockOwner ~= nil
	local ownerName: string? = nil
	if isLocked and worldData.lockOwner then
		local ownerPlayer = Players:GetPlayerByUserId(worldData.lockOwner)
		ownerName = ownerPlayer and ownerPlayer.Name or tostring(worldData.lockOwner)
	end
	PlayerManager.FireToPlayer(player, "WorldLockStatus", isLocked, ownerName)

	-- 8. Send gem count and inventory
	local gems = GemService.GetGems(player)
	local inventory = InventoryService.GetInventory(player)
	PlayerManager.FireToPlayer(player, "GemsUpdated", gems)
	PlayerManager.FireToPlayer(player, "InventoryUpdated", inventory)

	-- 9. Broadcast enter message to new world
	if oldWorld ~= normalized then
		local systemColor = Color3.fromRGB(180, 180, 180)
		PlayerManager.BroadcastToWorld(normalized, "ChatMessage", "", `→ {player.Name} entered the world`, systemColor)
	end

	-- 10. Update world tracking
	playerWorld[player.UserId] = normalized

	-- 11. Schedule old world unload if empty
	if oldWorld and oldWorld ~= normalized then
		PlayerManager.ScheduleWorldUnload(oldWorld)
	end

	print(`[PlayerManager] {player.Name} moved to world "{normalized}"`)
	return true, "Moved to " .. normalized
end

--[[
	===== WORLD UNLOAD MANAGEMENT =====
]]

--[[
	Schedule a world for unload after 30 seconds if no players remain.
	Cancel the unload if someone re-enters (via CancelWorldUnload).
	@param worldName: string
]]
function PlayerManager.ScheduleWorldUnload(worldName: string)
	local upperName = string.upper(worldName)

	-- Don't unload special worlds (START, etc.)
	if WorldService.IsSpecialWorld(upperName) then
		return
	end

	-- If already scheduled, don't duplicate
	if pendingUnloads[upperName] then
		return
	end

	local cancelled = false
	local unloadThread = task.delay(30, function()
		if cancelled then return end

		-- Double-check no players entered during the delay
		if PlayerManager.WorldHasPlayers(upperName) then
			pendingUnloads[upperName] = nil
			return
		end

		-- Unload the world
		WorldService.UnloadWorld(upperName)
		pendingUnloads[upperName] = nil
		print(`[PlayerManager] World "{upperName}" unloaded (30s idle)`)
	end)

	pendingUnloads[upperName] = {
		cancel = function()
			cancelled = true
			task.cancel(unloadThread)
		end,
	}

	print(`[PlayerManager] Scheduled unload for "{upperName}" in 30s`)
end

--[[
	Cancel a pending world unload.
	Called when a player enters a world that was scheduled for unload.
	@param worldName: string
]]
function PlayerManager.CancelWorldUnload(worldName: string)
	local upperName = string.upper(worldName)
	local pending = pendingUnloads[upperName]
	if pending then
		pending.cancel()
		pendingUnloads[upperName] = nil
		print(`[PlayerManager] Cancelled unload for "{upperName}"`)
	end
end

--[[
	===== PLAYER JOIN / LEAVE =====
]]

--[[
	Starter inventory items for new players (first join only).
	Format: { { itemId, count }, ... }
]]
local STARTER_ITEMS = {
	{ 1000, 1 },  -- Fist × 1 (always in slot 1, non-negotiable)
	{ 101, 10 },  -- Dirt Seed × 10
	{ 102, 10 },  -- Rock Seed × 10
	{ 103, 5 },   -- Cave Background Seed × 5
	{ 1002, 1 },  -- Wrench × 1
}

local STARTER_GEMS = 50

--[[
	Check if a player is a new player (no items in inventory, no gems earned).
	@param player: Player
	@return boolean
]]
local function isNewPlayer(player: Player): boolean
	local inv = InventoryService.GetInventory(player)
	if inv then
		for _, slot in ipairs(inv) do
			if slot and slot.count and slot.count > 0 then
				return false -- Has at least one item
			end
		end
	end

	-- Check gems
	local gems = GemService.GetGems(player)
	if gems > STARTER_GEMS then
		return false -- Has earned more gems than starter amount
	end

	return true
end

--[[
	Give starter inventory items to a new player.
	Called once on first join.
	@param player: Player
]]
local function grantStarterItems(player: Player)
	for _, entry in ipairs(STARTER_ITEMS) do
		local itemId = entry[1]
		local count = entry[2]
		InventoryService.AddItem(player, itemId, count)
	end

	-- Give starter gems (only if they don't already have them)
	local currentGems = GemService.GetGems(player)
	if currentGems < STARTER_GEMS then
		GemService.AddGems(player, STARTER_GEMS - currentGems)
	end

	print(`[PlayerManager] Granted starter items to {player.Name}`)
end

--[[
	Calculate spawn position for a player entering a world.
	Returns center of world at surface level.
	@param worldName: string
	@return number, number — tileX, tileY
]]
local function getSpawnPosition(worldName: string): (number, number)
	local doorX = math.floor(WorldConfig.WORLD_WIDTH / 2)
	local surfaceY = 5 -- Default surface Y (flat for START)
	return doorX, surfaceY
end

--[[
	Handle a player joining the game.
	- Loads player data (handled by DataService wiring)
	- Determines if new player → gives starter items
	- Moves player to world (START or last saved world)
	- Fires PlayerSpawned event to client
	@param player: Player
]]
--[[
	Re-fire PlayerSpawned when the player's character respawns (dies and re-creates).
	This ensures the client always knows where to place the character, even after death.
	@param player: Player
]]
local function ensureFistSlot1(player: Player)
	local inv = InventoryService.GetInventory(player)
	if inv then
		if inv[1] and inv[1].itemId == 1000 then
			return -- Already has fist in slot 1
		else
			InventoryService.AddItem(player, 1000, 1)
			local updatedInv = InventoryService.GetInventory(player)
			local fistSlot = nil
			for i = 1, #updatedInv do
				if updatedInv[i] and updatedInv[i].itemId == 1000 then
					fistSlot = i
					break
				end
			end
			if fistSlot and fistSlot ~= 1 then
				InventoryService.SwapSlots(player, fistSlot, 1)
			end
		end
	else
		InventoryService.AddItem(player, 1000, 1)
	end
end

local function ensureWrenchSlot2(player: Player)
	local inv = InventoryService.GetInventory(player)
	if inv then
		-- Only enforce if slot 2 is empty or not a Wrench
		local slot2 = inv[2]
		if slot2 and slot2.itemId == 1002 then
			return -- Already has wrench in slot 2
		else
			InventoryService.AddItem(player, 1002, 1)
			local updatedInv = InventoryService.GetInventory(player)
			local wrenchSlot = nil
			for i = 1, #updatedInv do
				if updatedInv[i] and updatedInv[i].itemId == 1002 then
					wrenchSlot = i
					break
				end
			end
			if wrenchSlot and wrenchSlot ~= 2 then
				InventoryService.SwapSlots(player, wrenchSlot, 2)
			end
		end
	else
		InventoryService.AddItem(player, 1002, 1)
	end
end

local function wireCharacterAdded(player: Player)
	player.CharacterAdded:Connect(function(newCharacter: Model)
		-- Wait a brief moment for the character to fully load
		task.wait(0.3)

		-- Assign every part of the character to the "Players" collision group
		-- so drops (in the "Drops" group) pass through the player without collision.
		for _, descendant in ipairs(newCharacter:GetDescendants()) do
			if descendant:IsA("BasePart") then
				PhysicsService:SetPartCollisionGroup(descendant, "Players")
			end
		end

		-- Ensure the Fist (itemId 1000) is always in slot 1, even after respawn
		ensureFistSlot1(player)
		-- Ensure the Wrench (itemId 1002) is always in slot 2, even after respawn
		ensureWrenchSlot2(player)

		-- Get the player's current world
		local worldName = playerWorld[player.UserId] or START_WORLD_NAME

		-- Fire PlayerSpawned with the center surface position
		local spawnX, spawnY = getSpawnPosition(worldName)
		PlayerManager.FireToPlayer(player, "PlayerSpawned", spawnX, spawnY, worldName)
		print(`[PlayerManager] {player.Name} respawned at ({spawnX}, {spawnY}) in "{worldName}" (CharacterAdded)`)

		-- CRITICAL: Set the server-side character CFrame to match what the client computes.
		-- Without this, the server's authoritative position differs from the client's,
		-- causing server-side distance checks (e.g., DropService pickup) to fail.
		local rootPart = newCharacter:FindFirstChild("HumanoidRootPart")
			or newCharacter:FindFirstChild("Torso")
			or newCharacter:FindFirstChild("UpperTorso")
		if rootPart then
			local spawnPos = Vector3.new(spawnX * TILE_SIZE, -spawnY * TILE_SIZE + TILE_SIZE, 0)
			rootPart.CFrame = CFrame.new(spawnPos)
		end
	end)
end

local function onPlayerAdded(player: Player)
	print(`[PlayerManager] Player joined: {player.Name} (UserId: {player.UserId})`)

	-- CRITICAL: Ensure player inventory data is initialized.
	-- DataService.WirePlayerEvents handles this for new PlayerAdded events,
	-- but for EXISTING players (already in game when server starts in Studio),
	-- DataService's handler never fires. We must init here to avoid nil inventory.
	-- IMPORTANT: Load saved data from ProfileStore instead of using empty defaults,
	-- otherwise returning players lose their inventory and gems.
	local invData = InventoryService._getInv(player)
	if not invData then
		-- Load saved data from ProfileStore for existing players in Studio
		local savedData = DataService.LoadPlayerData(player.UserId)
		if savedData then
			InventoryService.InitPlayerData(player.UserId, savedData.inventory)
			GemService.InitPlayerData(player.UserId, savedData.gems)
			print(`[PlayerManager] Restored saved data for existing player {player.Name} (userId={player.UserId})`)
		else
			InventoryService.InitPlayerData(player.UserId, {})
			GemService.InitPlayerData(player.UserId, WorldConfig.DEFAULT_GEMS or 0)
			print(`[PlayerManager] No saved data for existing player {player.Name}, using defaults`)
		end
	end

	-- Also start ProfileStore profile for existing players (DataService.WirePlayerEvents
	-- doesn't fire for them, so StartProfile is never called otherwise).
	-- This is needed for the auto-save loop to track active profiles.
	if not ProfileStore.GetProfile(player.UserId) then
		local gems = GemService.GetPlayerDataForSave(player.UserId)
		local inventory = InventoryService.GetPlayerDataForSave(player.UserId)
		ProfileStore.StartProfile(player.UserId, gems, inventory)
	end

	-- Wire CharacterAdded for respawn handling
	wireCharacterAdded(player)

	-- Ensure START world is generated and cached
	WorldService.GetOrCreateWorld(START_WORLD_NAME)

	-- Move player to START world after a short delay (wait for client to be ready)
	task.wait(1.5)

	local success, message = PlayerManager.MovePlayerToWorld(player, START_WORLD_NAME)
	if not success then
		warn(`[PlayerManager] Failed to move {player.Name} to START: {message}`)
		return
	end

	-- Check if this is a new player (empty inventory, no gems)
	if isNewPlayer(player) then
		grantStarterItems(player)
	else
		-- Ensure the Fist (itemId 1000) is always in slot 1, even for returning players
		ensureFistSlot1(player)
		-- Ensure the Wrench (itemId 1002) is always in slot 2, even for returning players
		ensureWrenchSlot2(player)
	end

	-- CRITICAL: Re-send inventory to client after starter items / fist enforcement
	-- DataService.WirePlayerEvents fires InventoryUpdated on PlayerAdded with the EMPTY/loaded inventory,
	-- but grantStarterItems adds items AFTER that. We need to send the updated inventory now.
	local finalInv = InventoryService.GetInventory(player)
	PlayerManager.FireToPlayer(player, "InventoryUpdated", finalInv)

	-- Fire PlayerSpawned event with spawn position
	local spawnX, spawnY = getSpawnPosition(START_WORLD_NAME)
	PlayerManager.FireToPlayer(player, "PlayerSpawned", spawnX, spawnY, START_WORLD_NAME)
	print(`[PlayerManager] {player.Name} spawned at ({spawnX}, {spawnY}) in "{START_WORLD_NAME}"`)

	-- CRITICAL: Set the server-side character CFrame for existing players at boot.
	-- For new players, wireCharacterAdded handles this when CharacterAdded fires.
	local character = player.Character
	if character then
		local rootPart = character:FindFirstChild("HumanoidRootPart")
			or character:FindFirstChild("Torso")
			or character:FindFirstChild("UpperTorso")
		if rootPart then
			local spawnPos = Vector3.new(spawnX * TILE_SIZE, -spawnY * TILE_SIZE + TILE_SIZE, 0)
			rootPart.CFrame = CFrame.new(spawnPos)
		end
	end
end

--[[
	Handle a player leaving the game.
	- Saves world data
	- Broadcasts leave message
	- Saves player data
	- Cleans up tracking
	@param player: Player
]]
local function onPlayerRemoving(player: Player)
	local worldName = playerWorld[player.UserId]
	print(`[PlayerManager] Player left: {player.Name} (was in "{worldName or "?"}")`)

	-- Broadcast leave message
	if worldName then
		local systemColor = Color3.fromRGB(180, 180, 180)
		PlayerManager.BroadcastToWorld(worldName, "ChatMessage", "", `← {player.Name} left the world`, systemColor)
	end

	-- Save player data (DataService handles this, but ensure it's called)
	DataService.SavePlayerData(player)

	-- Save the world they were in (in case they modified it)
	if worldName then
		local allWorlds = WorldService.GetAllWorlds()
		if allWorlds and allWorlds[worldName] then
			DataService.SaveWorldData(worldName, allWorlds[worldName])
		end
	end

	-- Clean up tracking
	playerWorld[player.UserId] = nil

	-- Schedule world unload
	if worldName then
		PlayerManager.ScheduleWorldUnload(worldName)
	end

	-- Clear throttle state
	RemoteEvents.ClearThrottleForPlayer(player)
end

--[[
	===== BACKWARD-COMPATIBLE FORWARDING METHODS =====
	The old BlockService, SeedService, and SpliceService reference PlayerManager.AddItem/HasItem/RemoveItem
	which the old module provided. These delegate to InventoryService.
]]

--[[
	Add items to a player's inventory.
	Backward compat: old services call PlayerManager.AddItem.
	@param player: Player
	@param itemId: number
	@param count: number
	@return boolean, number — success, overflow
]]
function PlayerManager.AddItem(player: Player, itemId: number, count: number): (boolean, number)
	if not InventoryService or not InventoryService.AddItem then
		return false, count
	end
	return InventoryService.AddItem(player, itemId, count)
end

--[[
	Check if a player has at least `count` of an item.
	Backward compat: old services call PlayerManager.HasItem.
	@param player: Player
	@param itemId: number
	@param count: number
	@return boolean
]]
function PlayerManager.HasItem(player: Player, itemId: number, count: number): boolean
	if not InventoryService or not InventoryService.HasItem then
		return false
	end
	return InventoryService.HasItem(player, itemId, count)
end

--[[
	Remove items from a player's inventory.
	Backward compat: old services call PlayerManager.RemoveItem.
	@param player: Player
	@param itemId: number
	@param count: number
	@return boolean
]]
function PlayerManager.RemoveItem(player: Player, itemId: number, count: number): boolean
	if not InventoryService or not InventoryService.RemoveItem then
		return false
	end
	return InventoryService.RemoveItem(player, itemId, count)
end

--[[
	Clear a player's inventory entirely.
	Backward compat: old services call PlayerManager.ClearInventory.
	@param player: Player
]]
function PlayerManager.ClearInventory(player: Player)
	if InventoryService and InventoryService.ClearInventory then
		InventoryService.ClearInventory(player)
	end
end

--[[
	===== INIT =====
]]

--[[
	Initialize PlayerManager.
	Wires PlayerAdded and PlayerRemoving events.
	Generates the START world on boot.
]]
function PlayerManager.Init()
	-- Wire join/leave
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- Also handle players already in the game (server was live before this init)
	-- NOTE: We call onPlayerAdded directly (not MovePlayerToWorld) so that
	-- existing players also get the isNewPlayer check, starter items, and
	-- PlayerSpawned event. DataService.WirePlayerEvents must have run first.
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end

	print("[PlayerManager] Initialized")
end

return PlayerManager
