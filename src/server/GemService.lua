--!strict
-- GemService.lua
-- In-memory gem/currency management per player
-- DataService loads into this on join and saves from this on leave
-- Fires RemoteEvents.GemsUpdated on every change

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RemoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)
local ItemDatabase = require(ReplicatedStorage.Shared.ItemDatabase)

local GemService = {}

-- Per-player gem counts: player.UserId -> number
local playerGems = {}

--[[
	Initialize a player's gem count (called by DataService on join).
	@param userId: number — the player's UserId
	@param amount: number? — starting gem count (nil = 0)
]]
function GemService.InitPlayerData(userId: number, amount: number?)
	playerGems[userId] = amount or 0
end

--[[
	Get a player's gem count for saving.
	Used by DataService on player leave.
	@param userId: number
	@return number
]]
function GemService.GetPlayerDataForSave(userId: number): number
	return playerGems[userId] or 0
end

--[[
	Clean up a player's gem data on leave.
	@param userId: number
]]
function GemService.ClearPlayerData(userId: number)
	playerGems[userId] = nil
end

--[[
	Fire gems-updated event to the player.
]]
function GemService._fireUpdate(player: Player, newTotal: number)
	RemoteEvents.GemsUpdated:FireClient(player, newTotal)
end

--[[
	Add gems to a player's balance.
	@param player: Player
	@param amount: number — amount to add
	@return number — new total
]]
function GemService.AddGems(player: Player, amount: number): number
	local userId = player.UserId
	local current = playerGems[userId] or 0
	current += amount
	playerGems[userId] = current

	print(`[GemService] {player.Name} +{amount} gems = {current}`)
	GemService._fireUpdate(player, current)
	return current
end

--[[
	Spend gems from a player's balance.
	@param player: Player
	@param amount: number — amount to spend
	@return boolean, number — false if insufficient, new total if success
]]
function GemService.SpendGems(player: Player, amount: number): (boolean, number)
	local userId = player.UserId
	local current = playerGems[userId] or 0

	if current < amount then
		print(`[GemService] {player.Name} tried to spend {amount} gems but only has {current}`)
		return false, current
	end

	current -= amount
	playerGems[userId] = current

	print(`[GemService] {player.Name} -{amount} gems = {current}`)
	GemService._fireUpdate(player, current)
	return true, current
end

--[[
	Get a player's current gem balance.
	@param player: Player
	@return number
]]
function GemService.GetGems(player: Player): number
	return playerGems[player.UserId] or 0
end

--[[
	Set a player's gem balance directly.
	@param player: Player
	@param amount: number — new balance
]]
function GemService.SetGems(player: Player, amount: number)
	playerGems[player.UserId] = amount
	GemService._fireUpdate(player, amount)
end

--[[
	Award gems for breaking a block.
	Rolls math.random(item.gemDropMin, item.gemDropMax).
	@param player: Player
	@param itemId: number — the item/block that was broken
	@return number — amount of gems awarded (0 if item has no gem drop)
]]
function GemService.AwardBlockBreakGems(player: Player, itemId: number): number
	local item = ItemDatabase.GetItem(itemId)
	if not item then
		return 0
	end

	local gemMin = item.gemDropMin or 0
	local gemMax = item.gemDropMax or 0

	if gemMin <= 0 or gemMax <= 0 then
		return 0
	end

	local awarded = if gemMin == gemMax then gemMin else math.random(gemMin, gemMax)
	if awarded > 0 then
		GemService.AddGems(player, awarded)
	end

	return awarded
end

--[[
	Initialize GemService.
]]
function GemService.Init()
	print("[GemService] Initialized")
end

return GemService
