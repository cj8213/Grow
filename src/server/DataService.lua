--!strict
-- DataService.lua
-- High-level persistence facade.
-- Delegates ALL DataStore operations to ProfileStore.
-- Provides the same API that other services expect:
--   - LoadPlayerData / SavePlayerData
--   - SaveWorldData / LoadWorldData
--   - WirePlayerEvents (PlayerAdded/PlayerRemoving)
--   - StartAutoSave
--
-- ProfileStore handles retries, session-locking, and sparse compression.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local WorldConfig = require(ReplicatedStorage.Shared.WorldConfig)
local RemoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)

local InventoryService = require(script.Parent.InventoryService)
local GemService = require(script.Parent.GemService)
local WorldService = require(script.Parent.WorldService)
local ProfileStore = require(script.Parent.ProfileStore)

local DataService = {}

--[[
	=== PLAYER DATA ===
]]

--[[
	Save a player's data (gems + inventory) to DataStore via ProfileStore.
	Called on PlayerRemoving and by auto-save loop.
	@param player: Player
	@return boolean — true if saved successfully
]]
function DataService.SavePlayerData(player: Player): boolean
	local userId = player.UserId
	local gems = GemService.GetPlayerDataForSave(userId)
	local inventory = InventoryService.GetPlayerDataForSave(userId)
	return ProfileStore.SavePlayerProfile(userId, gems, inventory)
end

--[[
	Load a player's data from DataStore via ProfileStore.
	Called on PlayerAdded.
	Returns nil if no data exists (new player).
	@param userId: number
	@return { gems: number, inventory: { { itemId: number, count: number }? }? }?
]]
function DataService.LoadPlayerData(userId: number): { gems: number, inventory: { { itemId: number, count: number }? }? }?
	return ProfileStore.LoadPlayerProfile(userId)
end

--[[
	=== WORLD DATA ===
]]

--[[
	Save a world's tiles to DataStore via ProfileStore.
	Uses sparse compression (only tiles differing from generated defaults).
	@param worldName: string
	@param worldData: table
	@return boolean
]]
function DataService.SaveWorldData(worldName: string, worldData: table): boolean
	return ProfileStore.SaveWorld(worldName, worldData)
end

--[[
	Load a world's tile data from DataStore via ProfileStore.
	Returns nil if no saved data exists.
	@param worldName: string
	@return table?
]]
function DataService.LoadWorldData(worldName: string): table?
	return ProfileStore.LoadWorld(worldName)
end

--[[
	=== AUTO-SAVE ===
]]

--[[
	Start the auto-save loop.
	Saves all online players and cached worlds every 60 seconds.
	Must be called ONCE from init.server.luau.
]]
function DataService.StartAutoSave()
	task.spawn(function()
		while true do
			task.wait(60)

			print("[DataService] Auto-save started")

			-- Save all online players
			local playerCount = 0
			for _, player in ipairs(Players:GetPlayers()) do
				local success = DataService.SavePlayerData(player)
				if success then
					playerCount += 1
				end
			end
			print(`[DataService] Auto-saved {playerCount} players`)

			-- Save all cached worlds via ProfileStore
			local worldCount = ProfileStore.SaveAllWorlds()
			print(`[DataService] Auto-saved {worldCount} worlds`)

			print("[DataService] Auto-save complete")
		end
	end)

	print("[DataService] Auto-save loop started (60s interval)")
end

--[[
	=== WIRING: PlayerAdded / PlayerRemoving ===
]]

--[[
	Wire up PlayerAdded and PlayerRemoving events:
	- On join: LoadPlayerData → populate InventoryService + GemService → start ProfileStore profile
	- On leave: SavePlayerData → end ProfileStore profile → cleanup InventoryService + GemService

	Must be called after InventoryService and GemService are initialized.
]]
function DataService.WirePlayerEvents()
	Players.PlayerAdded:Connect(function(player)
		-- Load saved data via ProfileStore
		local savedData = DataService.LoadPlayerData(player.UserId)

		-- Populate in-memory services
		if savedData then
			-- Existing player: restore saved state
			InventoryService.InitPlayerData(player.UserId, savedData.inventory)
			GemService.InitPlayerData(player.UserId, savedData.gems)
		else
			-- New player: defaults
			InventoryService.InitPlayerData(player.UserId, {})
			GemService.InitPlayerData(player.UserId, WorldConfig.DEFAULT_GEMS or 0)
		end

		-- Start ProfileStore profile (tracks active profiles for auto-save)
		local gems = GemService.GetPlayerDataForSave(player.UserId)
		local inventory = InventoryService.GetPlayerDataForSave(player.UserId)
		ProfileStore.StartProfile(player.UserId, gems, inventory)

		-- Send initial inventory to client
		local inv = InventoryService.GetInventory(player)
		RemoteEvents.InventoryUpdated:FireClient(player, inv)

		-- Send initial gems to client
		local gemsForClient = GemService.GetGems(player)
		RemoteEvents.GemsUpdated:FireClient(player, gemsForClient)
	end)

	Players.PlayerRemoving:Connect(function(player)
		-- Save data via ProfileStore (which handles retries)
		local userId = player.UserId
		local gems = GemService.GetPlayerDataForSave(userId)
		local inventory = InventoryService.GetPlayerDataForSave(userId)
		ProfileStore.EndProfile(userId, gems, inventory)

		-- Clean up in-memory state
		InventoryService.ClearPlayerData(userId)
		GemService.ClearPlayerData(userId)
	end)

	print("[DataService] Wired PlayerAdded/PlayerRemoving events (via ProfileStore)")
end

--[[
	Initialize DataService.
]]
function DataService.Init()
	ProfileStore.Init()
	print("[DataService] Initialized (backed by ProfileStore)")
end

return DataService
