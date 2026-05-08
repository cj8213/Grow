-- ItemDatabase.lua
-- Master item/block definitions for GrowRoblox
-- Every item in the game is defined here with its properties
-- IDs 1-100+ reserved for items, 1000+ for tools

local WorldConfig = require(script.Parent.WorldConfig)
local ItemTypes = WorldConfig.ItemTypes

local ItemDatabase = {}

ItemDatabase.Items = {}

-- Helper to register an item
local function define(id, data)
	data.id = id
	ItemDatabase.Items[id] = data
end

--[[
	=== TIER 1 — BASE WORLD ITEMS (IDs 1-6) ===
	These generate naturally in the world and can't be crafted/spliced.
	They are the building blocks of every world.
]]

-- 1: Dirt — the most common block, forms underground layers
define(1, {
	name = "Dirt",
	description = "Just dirt. The foundation of everything.",
	type = ItemTypes.SOLID,
	hp = 6,
	rarity = 1,
	growthTime = 30,
	seedDropChance = 0.5,
	gemDropMin = 1,
	gemDropMax = 2,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 101,
	color = Color3.fromRGB(139, 90, 43),
})

-- 2: Rock — hard block found in deep layers
define(2, {
	name = "Rock",
	description = "Hard and sturdy. Great for building foundations.",
	type = ItemTypes.SOLID,
	hp = 10,
	rarity = 2,
	growthTime = 60,
	seedDropChance = 0.4,
	gemDropMin = 1,
	gemDropMax = 3,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 102,       -- Rock Seed
	color = Color3.fromRGB(128, 128, 128),
})

-- 3: Cave Background — background layer tile in caves
define(3, {
	name = "Cave Background",
	type = ItemTypes.BACKGROUND,
	hp = 3,
	rarity = 1,
	growthTime = 20,
	seedDropChance = 0.6,
	gemDropMin = 0,
	gemDropMax = 1,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 103,       -- Cave Background Seed
	color = Color3.fromRGB(60, 60, 70),
})

-- 4: Lava — deadly liquid in deep layers
define(4, {
	name = "Lava",
	type = ItemTypes.LAVA,
	hp = 2,
	rarity = 3,
	growthTime = 90,
	seedDropChance = 0.3,
	gemDropMin = 2,
	gemDropMax = 5,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 104,       -- Lava Seed
	color = Color3.fromRGB(255, 69, 0),
})

-- 5: Bedrock — indestructible foundation block
define(5, {
	name = "Bedrock",
	type = ItemTypes.BEDROCK,
	hp = 99999,
	rarity = 5,
	growthTime = 0,
	seedDropChance = 0,
	gemDropMin = 0,
	gemDropMax = 0,
	isSplicable = false,
	unsplicable = true,
	tradeable = false,
	seedId = nil,
	color = Color3.fromRGB(20, 20, 20),
})

-- 6: Main Door — spawn point, exits to hub
define(6, {
	name = "Main Door",
	type = ItemTypes.DOOR,
	hp = 99999,
	rarity = 1,
	growthTime = 0,
	seedDropChance = 0,
	gemDropMin = 0,
	gemDropMax = 0,
	isSplicable = false,
	unsplicable = true,
	tradeable = false,
	seedId = nil,
	color = Color3.fromRGB(139, 69, 19),
})

--[[
	=== TIER 2 — CRAFTED ITEMS (IDs 7-15) ===
	Created by splicing Tier 1 seeds together.
]]

-- 7: Grass — surface growth block
define(7, {
	name = "Grass",
	type = ItemTypes.SOLID,
	hp = 6,
	rarity = 2,
	growthTime = 35,
	seedDropChance = 0.5,
	gemDropMin = 1,
	gemDropMax = 2,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 107,       -- Grass Seed
	color = Color3.fromRGB(34, 139, 34),
})

-- 8: Door — player-placed teleport door
define(8, {
	name = "Door",
	type = ItemTypes.DOOR,
	hp = 8,
	rarity = 3,
	growthTime = 45,
	seedDropChance = 0.4,
	gemDropMin = 1,
	gemDropMax = 3,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 108,       -- Door Seed
	color = Color3.fromRGB(160, 82, 45),
})

-- 9: Wood Block — basic building material
define(9, {
	name = "Wood Block",
	type = ItemTypes.SOLID,
	hp = 8,
	rarity = 2,
	growthTime = 40,
	seedDropChance = 0.45,
	gemDropMin = 1,
	gemDropMax = 2,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 109,       -- Wood Block Seed
	color = Color3.fromRGB(139, 119, 80),
})

-- 10: Glass Pane — transparent decorative block
define(10, {
	name = "Glass Pane",
	type = ItemTypes.SOLID,
	hp = 4,
	rarity = 3,
	growthTime = 50,
	seedDropChance = 0.35,
	gemDropMin = 1,
	gemDropMax = 3,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 110,       -- Glass Pane Seed
	color = Color3.fromRGB(173, 216, 230),
})

-- 11: Sign — display text block
define(11, {
	name = "Sign",
	type = ItemTypes.SIGN,
	hp = 5,
	rarity = 3,
	growthTime = 40,
	seedDropChance = 0.4,
	gemDropMin = 1,
	gemDropMax = 2,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 111,       -- Sign Seed
	color = Color3.fromRGB(210, 180, 140),
})

-- 12: Lava Rock — hardened lava block
define(12, {
	name = "Lava Rock",
	type = ItemTypes.SOLID,
	hp = 12,
	rarity = 4,
	growthTime = 70,
	seedDropChance = 0.3,
	gemDropMin = 2,
	gemDropMax = 4,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 112,       -- Lava Rock Seed
	color = Color3.fromRGB(80, 40, 20),
})

--[[
	=== TIER 3 ITEMS (IDs 13-25) ===
	Created from Tier 2 splicing.
]]

-- 13: Wooden Background
define(13, {
	name = "Wooden Background",
	type = ItemTypes.BACKGROUND,
	hp = 4,
	rarity = 3,
	growthTime = 40,
	seedDropChance = 0.45,
	gemDropMin = 1,
	gemDropMax = 2,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 113,
	color = Color3.fromRGB(120, 100, 70),
})

-- 14: Pointy Sign
define(14, {
	name = "Pointy Sign",
	type = ItemTypes.SIGN,
	hp = 5,
	rarity = 3,
	growthTime = 45,
	seedDropChance = 0.4,
	gemDropMin = 1,
	gemDropMax = 2,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 114,
	color = Color3.fromRGB(200, 170, 120),
})

-- 15: Crappy Sign
define(15, {
	name = "Crappy Sign",
	type = ItemTypes.SIGN,
	hp = 4,
	rarity = 2,
	growthTime = 30,
	seedDropChance = 0.5,
	gemDropMin = 1,
	gemDropMax = 1,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 115,
	color = Color3.fromRGB(180, 150, 100),
})

-- 16: Daisy — small decorative flower block
define(16, {
	name = "Daisy",
	type = ItemTypes.SOLID,
	hp = 4,
	rarity = 2,
	growthTime = 25,
	seedDropChance = 0.55,
	gemDropMin = 1,
	gemDropMax = 2,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 116,
	color = Color3.fromRGB(255, 255, 224),
})

-- 17: Wooden Platform — walkable top, pass-through from below
define(17, {
	name = "Wooden Platform",
	type = ItemTypes.PLATFORM,
	hp = 6,
	rarity = 3,
	growthTime = 40,
	seedDropChance = 0.4,
	gemDropMin = 1,
	gemDropMax = 2,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 117,
	color = Color3.fromRGB(150, 120, 70),
})

-- 18: Rock Background
define(18, {
	name = "Rock Background",
	type = ItemTypes.BACKGROUND,
	hp = 5,
	rarity = 3,
	growthTime = 45,
	seedDropChance = 0.4,
	gemDropMin = 1,
	gemDropMax = 3,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 118,
	color = Color3.fromRGB(100, 100, 110),
})

-- 19: Bricks
define(19, {
	name = "Bricks",
	type = ItemTypes.SOLID,
	hp = 12,
	rarity = 3,
	growthTime = 50,
	seedDropChance = 0.35,
	gemDropMin = 1,
	gemDropMax = 3,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 119,
	color = Color3.fromRGB(180, 80, 60),
})

-- 20: Rose
define(20, {
	name = "Rose",
	type = ItemTypes.SOLID,
	hp = 3,
	rarity = 3,
	growthTime = 30,
	seedDropChance = 0.5,
	gemDropMin = 1,
	gemDropMax = 3,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 120,
	color = Color3.fromRGB(255, 50, 50),
})

-- 21: Torch
define(21, {
	name = "Torch",
	type = ItemTypes.SOLID,
	hp = 3,
	rarity = 3,
	growthTime = 35,
	seedDropChance = 0.45,
	gemDropMin = 1,
	gemDropMax = 2,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 121,
	color = Color3.fromRGB(255, 165, 0),
})

-- 22: Mushroom
define(22, {
	name = "Mushroom",
	type = ItemTypes.SOLID,
	hp = 3,
	rarity = 3,
	growthTime = 35,
	seedDropChance = 0.5,
	gemDropMin = 1,
	gemDropMax = 2,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 122,
	color = Color3.fromRGB(200, 100, 200),
})

-- 23: Amber Glass
define(23, {
	name = "Amber Glass",
	type = ItemTypes.SOLID,
	hp = 4,
	rarity = 4,
	growthTime = 55,
	seedDropChance = 0.35,
	gemDropMin = 2,
	gemDropMax = 3,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 123,
	color = Color3.fromRGB(255, 191, 0),
})

-- 24: Super Crate Box (decorative)
define(24, {
	name = "Super Crate Box",
	type = ItemTypes.SOLID,
	hp = 10,
	rarity = 4,
	growthTime = 60,
	seedDropChance = 0.3,
	gemDropMin = 2,
	gemDropMax = 4,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 124,
	color = Color3.fromRGB(210, 150, 30),
})

-- 25: Cargo Shorts (wearable — kept as item for now)
define(25, {
	name = "Cargo Shorts",
	type = ItemTypes.CLOTHES,
	hp = 1,
	rarity = 3,
	growthTime = 40,
	seedDropChance = 0.4,
	gemDropMin = 1,
	gemDropMax = 2,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 125,
	color = Color3.fromRGB(100, 150, 80),
})

--[[
	=== SPECIAL ITEMS (IDs 26-30) ===
]]

-- 26: World Lock — locks an entire world
define(26, {
	name = "World Lock",
	type = ItemTypes.LOCK,
	hp = 20,
	rarity = 5,
	growthTime = 0,
	seedDropChance = 0,
	gemDropMin = 0,
	gemDropMax = 0,
	isSplicable = false,
	unsplicable = true,
	tradeable = true,
	seedId = nil,
	color = Color3.fromRGB(255, 215, 0),
})

-- 27: Small Lock — locks a local area
define(27, {
	name = "Small Lock",
	type = ItemTypes.LOCK,
	hp = 15,
	rarity = 4,
	growthTime = 0,
	seedDropChance = 0,
	gemDropMin = 0,
	gemDropMax = 0,
	isSplicable = false,
	unsplicable = true,
	tradeable = true,
	seedId = nil,
	color = Color3.fromRGB(192, 192, 192),
})

-- 28: Gems (the non-tradeable currency item)
define(28, {
	name = "Gems",
	type = ItemTypes.GEMS,
	hp = 1,
	rarity = 1,
	growthTime = 0,
	seedDropChance = 0,
	gemDropMin = 0,
	gemDropMax = 0,
	isSplicable = false,
	unsplicable = true,
	tradeable = false,
	seedId = nil,
	color = Color3.fromRGB(0, 255, 0),
})

-- 29: Sugar Cane
define(29, {
	name = "Sugar Cane",
	type = ItemTypes.SOLID,
	hp = 5,
	rarity = 3,
	growthTime = 40,
	seedDropChance = 0.4,
	gemDropMin = 1,
	gemDropMax = 3,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 129,
	color = Color3.fromRGB(50, 205, 50),
})

-- 30: Window
define(30, {
	name = "Window",
	type = ItemTypes.BACKGROUND,
	hp = 3,
	rarity = 3,
	growthTime = 30,
	seedDropChance = 0.45,
	gemDropMin = 1,
	gemDropMax = 2,
	isSplicable = true,
	unsplicable = false,
	tradeable = true,
	seedId = 130,
	color = Color3.fromRGB(173, 216, 230),
})

--[[
	=== SEEDS (IDs 101-130+) ===
	Seeds are separate items from blocks.
	Each block type has a corresponding seed.
]]

-- Seed definitions (these are placed-in-world items)
local seedDefs = {}

-- Auto-generate seed entries from block items
for id, item in pairs(ItemDatabase.Items) do
	if item.seedId then
		seedDefs[item.seedId] = {
			name = item.name .. " Seed",
			type = ItemTypes.SEED,
			color = item.color,
			parentBlockId = id,
			growthTime = item.growthTime,
			rarity = item.rarity,
			isSplicable = item.isSplicable,
			tradeable = item.tradeable,
		}
	end
end

ItemDatabase.SeedDefs = seedDefs

--[[
	=== TOOLS (IDs 1000+) ===
]]
define(1000, {
	name = "Fist",
	type = ItemTypes.FIST,
	hp = 99999,
	rarity = 1,
	growthTime = 0,
	seedDropChance = 0,
	gemDropMin = 0,
	gemDropMax = 0,
	isSplicable = false,
	unsplicable = true,
	tradeable = false,
	damage = 1,
	breakPower = 1,
	color = Color3.fromRGB(200, 180, 150),
})

define(1001, {
	name = "Axe",
	type = ItemTypes.FIST,
	hp = 99999,
	rarity = 2,
	growthTime = 0,
	seedDropChance = 0,
	gemDropMin = 0,
	gemDropMax = 0,
	isSplicable = false,
	unsplicable = true,
	tradeable = false,
	damage = 2,
	breakPower = 3,
	color = Color3.fromRGB(160, 120, 80),
})

define(1002, {
	name = "Wrench",
	type = ItemTypes.FIST,
	hp = 99999,
	rarity = 2,
	growthTime = 0,
	seedDropChance = 0,
	gemDropMin = 0,
	gemDropMax = 0,
	isSplicable = false,
	unsplicable = true,
	tradeable = false,
	damage = 1,
	breakPower = 1,
	color = Color3.fromRGB(180, 180, 100),
})

define(1003, {
	name = "Scissors",
	type = ItemTypes.FIST,
	hp = 99999,
	rarity = 2,
	growthTime = 0,
	seedDropChance = 0,
	gemDropMin = 0,
	gemDropMax = 0,
	isSplicable = false,
	unsplicable = true,
	tradeable = false,
	damage = 1,
	breakPower = 2,
	color = Color3.fromRGB(200, 100, 100),
})

define(1004, {
	name = "Shovel",
	type = ItemTypes.FIST,
	hp = 99999,
	rarity = 2,
	growthTime = 0,
	seedDropChance = 0,
	gemDropMin = 0,
	gemDropMax = 0,
	isSplicable = false,
	unsplicable = true,
	tradeable = false,
	damage = 1,
	breakPower = 2,
	color = Color3.fromRGB(140, 160, 180),
})

--[[
	=== PUBLIC API ===
]]

function ItemDatabase.GetItem(id: number)
	return ItemDatabase.Items[id] or ItemDatabase.SeedDefs[id]
end

function ItemDatabase.GetSeed(seedId: number)
	return ItemDatabase.SeedDefs[seedId]
end

function ItemDatabase.IsSeed(id: number): boolean
	return ItemDatabase.SeedDefs[id] ~= nil
end

function ItemDatabase.IsBreakable(id: number): boolean
	local item = ItemDatabase.Items[id]
	if not item then return false end
	return item.hp < 99999 and item.type ~= ItemTypes.BEDROCK
end

function ItemDatabase.GetSeedIdForBlock(blockId: number): number?
	local item = ItemDatabase.Items[blockId]
	if item then return item.seedId end
	return nil
end

function ItemDatabase.GetBlockIdForSeed(seedId: number): number?
	local seed = ItemDatabase.SeedDefs[seedId]
	if seed then return seed.parentBlockId end
	return nil
end

-- For backwards compatibility with old code that references by name
function ItemDatabase.GetItemByName(name: string)
	for _, item in pairs(ItemDatabase.Items) do
		if item.name == name then
			return item
		end
	end
	return nil
end

-- Verify all items are defined
local itemCount = 0
for _ in pairs(ItemDatabase.Items) do itemCount += 1 end
local seedCount = 0
for _ in pairs(ItemDatabase.SeedDefs) do seedCount += 1 end

print(`[ItemDatabase] Loaded {itemCount} items and {seedCount} seeds`)

return ItemDatabase
