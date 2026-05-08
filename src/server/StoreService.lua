--!strict
-- StoreService.lua (server)
-- In-game store: players spend gems to buy items (World Locks, Small Locks, Seeds)
-- Single atomic check: verify gems → AddItem → spend gems (refund overflow)
-- The ONLY file that calls both GemService.SpendGems and InventoryService.AddItem

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldConfig = require(ReplicatedStorage.Shared.WorldConfig)
local ItemDatabase = require(ReplicatedStorage.Shared.ItemDatabase)
local RemoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)

local InventoryService = require(script.Parent.InventoryService)
local GemService = require(script.Parent.GemService)

local StoreService = {}

--[[
	===== CATALOG =====
	itemId: the item ID from ItemDatabase (for blocks/seeds) or special items like locks
	price: gem cost per unit
	name: display name in the store
	description: short description shown in the store
	isSeed: true if this item is a seed (the store shows seed of parent block)
]]

local CATALOG: { { itemId: number, name: string, price: number, description: string, isSeed: boolean? } } = {
	{
		itemId = 26,
		name = "World Lock",
		price = 200,
		description = "Locks your entire world.",
		isSeed = false,
	},
	{
		itemId = 27,
		name = "Small Lock",
		price = 50,
		description = "Locks a 10x10 area.",
		isSeed = false,
	},
	{
		itemId = 101, -- Dirt Seed (seed of Dirt, item 1)
		name = "Dirt Seed",
		price = 10,
		description = "Grow dirt trees.",
		isSeed = true,
	},
	{
		itemId = 102, -- Rock Seed (seed of Rock, item 2)
		name = "Rock Seed",
		price = 10,
		description = "Grow rock trees.",
		isSeed = true,
	},
	{
		itemId = 103, -- Cave Background Seed (seed of Cave Background, item 3)
		name = "Cave Background Seed",
		price = 15,
		description = "Grow cave background trees.",
		isSeed = true,
	},
	{
		itemId = 104, -- Lava Seed (seed of Lava, item 4)
		name = "Lava Seed",
		price = 50,
		description = "Grow lava trees.",
		isSeed = true,
	},
	{
		itemId = 107, -- Grass Seed
		name = "Grass Seed",
		price = 25,
		description = "Grow grass trees.",
		isSeed = true,
	},
	{
		itemId = 108, -- Door Seed
		name = "Door Seed",
		price = 40,
		description = "Grow door trees.",
		isSeed = true,
	},
	{
		itemId = 109, -- Wood Block Seed
		name = "Wood Block Seed",
		price = 30,
		description = "Grow wood trees.",
		isSeed = true,
	},
}

-- Cache catalog by itemId for fast lookup
local catalogByItemId: { [number]: table } = {}
for _, entry in ipairs(CATALOG) do
	catalogByItemId[entry.itemId] = entry
end

--[[
	Get the full store catalog.
	Each entry includes the item name/color from ItemDatabase for display.

	@return { { itemId: number, name: string, price: number, description: string, color: Color3?, isSeed: boolean, parentBlockId: number? } }
]]
function StoreService.GetCatalog(): { table }
	local result: { table } = {}

	for _, entry in ipairs(CATALOG) do
		local catalogItem = {
			itemId = entry.itemId,
			name = entry.name,
			price = entry.price,
			description = entry.description,
			isSeed = entry.isSeed or false,
		}

		-- Get item color from ItemDatabase for display
		local itemDef = ItemDatabase.GetItem(entry.itemId)
		if itemDef then
			catalogItem.color = itemDef.color
		else
			-- It's a seed — get color from seed def
			local seedDef = ItemDatabase.GetSeed(entry.itemId)
			if seedDef then
				catalogItem.color = seedDef.color
			end
			-- Also get parent block info for seeds
			if entry.isSeed then
				local parentBlockId = ItemDatabase.GetBlockIdForSeed(entry.itemId)
				if parentBlockId then
					local parentDef = ItemDatabase.GetItem(parentBlockId)
					if parentDef then
						catalogItem.parentBlockName = parentDef.name
						catalogItem.parentBlockId = parentBlockId
						if not catalogItem.color then
							catalogItem.color = parentDef.color
						end
					end
				end
			end
		end

		table.insert(result, catalogItem)
	end

	return result
end

--[[
	Process a purchase from the store.

	Atomic check sequence:
	1. Validate itemId is in catalog
	2. Validate quantity (1–99)
	3. Calculate total price (price * quantity)
	4. Check if player has enough gems (fail early if not)
	5. Call InventoryService.AddItem (which may return overflow if inventory is full)
	6. If AddItem returns overflow > 0:
	   a. Calculate gems to refund: refundGems = (overflow / quantity) * totalPrice... 
	      Actually, refund proportionally: refundGems = math.floor(overflow * price)
	   b. Only spend gems for what was actually added
	7. Spend gems for the amount that was successfully added
	8. Fire InventoryUpdated + GemsUpdated to player
	9. Fire StoreResult to player with success/fail message

	@param player: Player — the purchasing player
	@param itemId: number — the catalog item ID to buy
	@param quantity: number — how many to buy (1–99)
	@return boolean, string — success status and message
]]
function StoreService.Purchase(player: Player, itemId: number, quantity: number): (boolean, string)
	-- 1. Validate player
	if not player or not player.UserId then
		return false, "Invalid player"
	end

	-- 2. Validate item is in catalog
	local catalogEntry = catalogByItemId[itemId]
	if not catalogEntry then
		return false, "Item not found in store"
	end

	-- 3. Validate quantity
	if type(quantity) ~= "number" or quantity < 1 or quantity > 99 then
		return false, "Invalid quantity (1–99)"
	end

	-- 4. Calculate total price
	local totalPrice = catalogEntry.price * quantity

	-- 5. Check if player has enough gems (fail early)
	local currentGems = GemService.GetGems(player)
	if currentGems < totalPrice then
		return false, `Not enough gems! Need ◆{totalPrice}, have ◆{currentGems}`
	end

	-- 6. Try to add items to inventory (this handles stacking, overflow)
	local success, overflow = InventoryService.AddItem(player, itemId, quantity)

	-- Calculate how many were actually added
	local added = quantity - overflow

	if added <= 0 then
		return false, "Inventory is full!"
	end

	-- 7. Calculate actual cost (only pay for what was added)
	local actualCost = catalogEntry.price * added

	-- 8. Spend gems
	local gemSuccess = GemService.SpendGems(player, actualCost)
	if not gemSuccess then
		-- Shouldn't happen since we checked, but rollback inventory just in case
		InventoryService.RemoveItem(player, itemId, added)
		return false, "Gem transaction failed"
	end

	-- 9. Fire updated inventory + gems to player
	local remoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)
	local PlayerManager = require(script.Parent.PlayerManager)
	PlayerManager.FireToPlayer(player, "InventoryUpdated", InventoryService.GetInventory(player))
	PlayerManager.FireToPlayer(player, "GemsUpdated", GemService.GetGems(player))

	-- 10. Notify player of success
	local message = `Purchased {added}x {catalogEntry.name} for ◆{actualCost}`
	if overflow > 0 then
		message = `Purchased {added}x {catalogEntry.name} for ◆{actualCost} (inventory full, {overflow} overflow)`
	end
	PlayerManager.FireToPlayer(player, "StoreResult", true, message)

	print(`[StoreService] {player.Name} bought {added}x {catalogEntry.name} (itemId={itemId}) for ◆{actualCost}`)
	return true, message
end

--[[
	Initialize StoreService.
]]
function StoreService.Init()
	print(`[StoreService] Initialized — {#CATALOG} catalog items`)
end

return StoreService
