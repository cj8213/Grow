--!strict
-- InventoryService.lua
-- In-memory inventory management per player
-- DataService loads into this on join and saves from this on leave
-- No DataStore calls — in-memory only

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RemoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)
local WorldConfig = require(ReplicatedStorage.Shared.WorldConfig)

local InventoryService = {}

-- Per-player inventory state: player.UserId -> { inventory, equippedSlot }
local playerInventories = {}

--[[
	Initialize a player's inventory data (called by DataService on join).
	@param userId: number — the player's UserId
	@param data: { { itemId: number, count: number }? }? — saved inventory data
]]
function InventoryService.InitPlayerData(userId: number, data: { { itemId: number, count: number }? }?)
	playerInventories[userId] = {
		inventory = data or {},
		equippedSlot = 1,
	}
end

--[[
	Clean up a player's inventory data on leave.
	@param userId: number — the player's UserId
]]
function InventoryService.ClearPlayerData(userId: number)
	playerInventories[userId] = nil
end

--[[
	Get a player's inventory data for saving (live reference, not a copy).
	Used by DataService on player leave.
	@param userId: number
	@return { { itemId: number, count: number }? }?
]]
function InventoryService.GetPlayerDataForSave(userId: number): { { itemId: number, count: number }? }?
	local data = playerInventories[userId]
	if not data then return nil end
	return data.inventory
end

--[[
	Get the internal inventory state for a player.
	@param player: Player
	@return { { itemId: number, count: number }? }?
]]
function InventoryService._getInv(player: Player): { { itemId: number, count: number }? }?
	local data = playerInventories[player.UserId]
	if not data then return nil end
	return data.inventory
end

--[[
	Fire inventory update to the client.
]]
function InventoryService._fireUpdate(player: Player)
	local inv = InventoryService._getInv(player)
	if not inv then
		return
	end
	RemoteEvents.InventoryUpdated:FireClient(player, inv)
end

--[[
	Add items to a player's inventory.
	Fills existing stacks first, then empty slots.
	Max 200 per stack, max 32 slots.
	@param player: Player
	@param itemId: number
	@param count: number
	@return boolean, number — true if at least some items fit, overflow count
]]
function InventoryService.AddItem(player: Player, itemId: number, count: number): (boolean, number)
	local inv = InventoryService._getInv(player)
	if not inv then return false, count end

	local remaining = count
	local MAX_SLOTS = WorldConfig.MAX_INVENTORY_SLOTS or 32
	local MAX_STACK = WorldConfig.MAX_STACK_SIZE or 200

	-- Phase 1: fill existing stacks (first-fit)
	for i = 1, MAX_SLOTS do
		if remaining <= 0 then break end
		local slot = inv[i]
		if slot and slot.itemId == itemId and slot.count < MAX_STACK then
			local space = MAX_STACK - slot.count
			local toAdd = math.min(space, remaining)
			slot.count += toAdd
			remaining -= toAdd
		end
	end

	-- Phase 2: fill empty slots
	for i = 1, MAX_SLOTS do
		if remaining <= 0 then break end
		if inv[i] == nil then
			local toAdd = math.min(MAX_STACK, remaining)
			inv[i] = { itemId = itemId, count = toAdd }
			remaining -= toAdd
		end
	end

	-- Fire update to client
	InventoryService._fireUpdate(player)

	if remaining > 0 then
		warn(`[InventoryService] {player.Name} inventory full! Overflow: {remaining} of item {itemId}`)
		return false, remaining
	end

	return true, 0
end

--[[
	Remove items from a player's inventory.
	Removes from first matching stack, cascades to next if needed.
	@param player: Player
	@param itemId: number
	@param count: number
	@return boolean — false if player doesn't have enough
]]
function InventoryService.RemoveItem(player: Player, itemId: number, count: number): boolean
	local inv = InventoryService._getInv(player)
	if not inv then return false end

	local MAX_SLOTS = WorldConfig.MAX_INVENTORY_SLOTS or 32
	local remaining = count

	for i = 1, MAX_SLOTS do
		if remaining <= 0 then break end
		local slot = inv[i]
		if slot and slot.itemId == itemId then
			if slot.count >= remaining then
				slot.count -= remaining
				remaining = 0
				if slot.count <= 0 then
					inv[i] = nil
				end
			else
				remaining -= slot.count
				inv[i] = nil
			end
		end
	end

	if remaining > 0 then
		warn(`[InventoryService] {player.Name} doesn't have enough of item {itemId}! Missing {remaining}`)
		return false
	end

	InventoryService._fireUpdate(player)
	return true
end

--[[
	Check if a player has a certain amount of an item.
	@param player: Player
	@param itemId: number
	@param count: number
	@return boolean
]]
function InventoryService.HasItem(player: Player, itemId: number, count: number): boolean
	local inv = InventoryService._getInv(player)
	if not inv then return false end

	local MAX_SLOTS = WorldConfig.MAX_INVENTORY_SLOTS or 32
	local total = 0
	for i = 1, MAX_SLOTS do
		local slot = inv[i]
		if slot and slot.itemId == itemId then
			total += slot.count
			if total >= count then
				return true
			end
		end
	end

	return total >= count
end

--[[
	Get a deep copy of a player's inventory.
	Never returns the live table — prevents external mutation.
	@param player: Player
	@return { { itemId: number, count: number }? }[]
]]
function InventoryService.GetInventory(player: Player): { { itemId: number, count: number }? }
	local inv = InventoryService._getInv(player)
	if not inv then
		return {}
	end

	local MAX_SLOTS = WorldConfig.MAX_INVENTORY_SLOTS or 32
	local copy: { { itemId: number, count: number }? } = {}
	for i = 1, MAX_SLOTS do
		local slot = inv[i]
		if slot then
			copy[i] = {
				itemId = slot.itemId,
				count = slot.count,
			}
		end
	end

	return copy
end

--[[
	Get the total count of a specific item in the player's inventory.
	@param player: Player
	@param itemId: number
	@return number
]]
function InventoryService.GetItemCount(player: Player, itemId: number): number
	local inv = InventoryService._getInv(player)
	if not inv then return 0 end

	local MAX_SLOTS = WorldConfig.MAX_INVENTORY_SLOTS or 32
	local total = 0
	for i = 1, MAX_SLOTS do
		local slot = inv[i]
		if slot and slot.itemId == itemId then
			total += slot.count
		end
	end

	return total
end

--[[
	Swap two inventory slots (for UI drag-and-drop reordering).
	@param player: Player
	@param slotA: number — 1-based slot index
	@param slotB: number — 1-based slot index
	@return boolean — true if swap succeeded
]]
function InventoryService.SwapSlots(player: Player, slotA: number, slotB: number): boolean
	local inv = InventoryService._getInv(player)
	if not inv then return false end

	local MAX_SLOTS = WorldConfig.MAX_INVENTORY_SLOTS or 32
	if slotA < 1 or slotA > MAX_SLOTS or slotB < 1 or slotB > MAX_SLOTS then
		return false
	end

	inv[slotA], inv[slotB] = inv[slotB], inv[slotA]

	-- Clean up: if a slot is empty (count <= 0), set to nil
	if inv[slotA] and inv[slotA].count <= 0 then inv[slotA] = nil end
	if inv[slotB] and inv[slotB].count <= 0 then inv[slotB] = nil end

	InventoryService._fireUpdate(player)
	return true
end

--[[
	Get the item ID in the player's currently equipped hotbar slot.
	@param player: Player
	@return number? — item ID or nil if slot is empty
]]
function InventoryService.GetEquippedItem(player: Player): number?
	local data = playerInventories[player.UserId]
	if not data then return nil end

	local inv = data.inventory
	local slot = inv[data.equippedSlot]
	if not slot then return nil end

	return slot.itemId
end

--[[
	Set the player's equipped (selected) hotbar slot.
	@param player: Player
	@param slotIndex: number — 1-9
	@return boolean — true if valid
]]
function InventoryService.SetEquippedSlot(player: Player, slotIndex: number): boolean
	local data = playerInventories[player.UserId]
	if not data then return false end

	local HOTBAR_SLOTS = WorldConfig.HOTBAR_SLOTS or 9
	if slotIndex < 1 or slotIndex > HOTBAR_SLOTS then
		return false
	end

	data.equippedSlot = slotIndex
	return true
end

--[[
	Get the player's currently equipped slot index.
	@param player: Player
	@return number — slot index (1-9)
]]
function InventoryService.GetEquippedSlot(player: Player): number
	local data = playerInventories[player.UserId]
	if not data then return 1 end
	return data.equippedSlot
end

--[[
	Clear a player's entire inventory.
	@param player: Player
]]
function InventoryService.ClearInventory(player: Player)
	local data = playerInventories[player.UserId]
	if not data then return end
	data.inventory = {}
	InventoryService._fireUpdate(player)
end

--[[
	Initialize InventoryService (no-op, state is managed per-player).
]]
function InventoryService.Init()
	print("[InventoryService] Initialized")
end

return InventoryService
