-- Enums.luau
-- Shared enumerations for Growtopia-in-Roblox

local Enums = {}

-- Block IDs (each block is also an item you can hold)
Enums.BlockID = {
	-- Base blocks
	DIRT = 1,
	CAVE_BACKGROUND = 2,
	GRASS = 3,
	LAVA = 4,
	ROCK = 5,
	DAISY = 6,
	SUGAR_CANE = 7,
	WINDOW = 8,
	CAVE_ENTRANCE = 9,
	BEDROCK = 10,

	-- Trees (placed as models, not voxels, but we use IDs for item reference)
	DIRT_TREE = 20,
	GRASS_TREE = 21,
	STONE_TREE = 22,

	-- Seeds (these are "blocks" when planted, items when held)
	DIRT_SEED = 100,
	CAVE_BACKGROUND_SEED = 101,
	GRASS_SEED = 102,
	LAVA_SEED = 103,
	ROCK_SEED = 104,
	DAISY_SEED = 105,
	SUGAR_CANE_SEED = 106,
	WINDOW_SEED = 107,
	CAVE_ENTRANCE_SEED = 108,

	-- Growth stages (intermediate states)
	DIRT_SPROUT = 200,
	CAVE_BACKGROUND_SPROUT = 201,
	GRASS_SPROUT = 202,
	LAVA_SPROUT = 203,
	ROCK_SPROUT = 204,
	DAISY_SPROUT = 205,
	SUGAR_CANE_SPROUT = 206,
	WINDOW_SPROUT = 207,
	CAVE_ENTRANCE_SPROUT = 208,

	-- Air (empty)
	AIR = 0,
}

-- Item IDs (non-block items like tools)
-- Use high values to avoid conflicting with BlockIDs
Enums.ItemID = {
	FIST = 1000,
	AXE = 1001,
	WRENCH = 1002,
	SCISSORS = 1003,
	SHOVEL = 1004,
}

-- Block categories
Enums.BlockCategory = {
	SOLID = "Solid",
	SEED = "Seed",
	SPROUT = "Sprout",
	BACKGROUND = "Background",
	LIQUID = "Liquid",
	TREE = "Tree",
}

-- Tool types
Enums.ToolType = {
	FIST = "Fist",
	AXE = "Axe",
	WRENCH = "Wrench",
	SCISSORS = "Scissors",
	SHOVEL = "Shovel",
}

-- Tree types
Enums.TreeType = {
	DIRT_TREE = "DirtTree",
	GRASS_TREE = "GrassTree",
	STONE_TREE = "StoneTree",
}

-- World permissions
Enums.WorldPermission = {
	OWNER = "Owner",
	BUILDER = "Builder",
	VISITOR = "Visitor",
	PUBLIC = "Public",
}

-- Function to get tree type from seed ID
function Enums.GetTreeTypeFromSeed(seedId: number): string?
	local mapping = {
		[Enums.BlockID.DIRT_SEED] = Enums.TreeType.DIRT_TREE,
		[Enums.BlockID.GRASS_SEED] = Enums.TreeType.GRASS_TREE,
		[Enums.BlockID.ROCK_SEED] = Enums.TreeType.STONE_TREE,
	}
	return mapping[seedId]
end

-- Function to get tree block ID from tree type
function Enums.GetTreeBlockId(treeType: string): number?
	local mapping = {
		[Enums.TreeType.DIRT_TREE] = Enums.BlockID.DIRT_TREE,
		[Enums.TreeType.GRASS_TREE] = Enums.BlockID.GRASS_TREE,
		[Enums.TreeType.STONE_TREE] = Enums.BlockID.STONE_TREE,
	}
	return mapping[treeType]
end

-- Function to get drop items for a tree type
function Enums.GetTreeDrops(treeType: string): ({ blockId: number, seedId: number }?)
	local mapping = {
		[Enums.TreeType.DIRT_TREE] = { blockId = Enums.BlockID.DIRT, seedId = Enums.BlockID.DIRT_SEED },
		[Enums.TreeType.GRASS_TREE] = { blockId = Enums.BlockID.GRASS, seedId = Enums.BlockID.GRASS_SEED },
		[Enums.TreeType.STONE_TREE] = { blockId = Enums.BlockID.ROCK, seedId = Enums.BlockID.ROCK_SEED },
	}
	return mapping[treeType]
end

return Enums
