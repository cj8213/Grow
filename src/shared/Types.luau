-- Types.luau
-- Shared type definitions for strict checking

local Types = {}

--[[
	BlockData: Represents a block in the world
	@field id: BlockID enum value
	@field extra: Optional extra data (for modified/spliced blocks)
]]
type BlockData = {
	id: number,
	extra: { [string]: any }?,
}

--[[
	ItemStack: Represents a stack of items in inventory
	@field id: BlockID or ItemID
	@field count: Number of items in stack
]]
type ItemStack = {
	id: number,
	count: number,
}

--[[
	InventoryData: Player inventory
	@field slots: Array of ItemStack (nil = empty slot)
	@field gems: Number of gems
	@field maxSlots: Max inventory slots
]]
type InventoryData = {
	slots: { ItemStack? },
	gems: number,
	maxSlots: number,
}

--[[
	WorldData: Represents a player's world
	@field name: World name
	@field ownerId: Player user ID
	@field blocks: 3D array of BlockData (x, y, z)
	@field permissions: Dictionary of userId -> permission level
]]
type WorldData = {
	name: string,
	ownerId: number,
	blocks: { { { BlockData? } } },
	permissions: { [number]: string },
}

--[[
	ChunkCoord: Chunk coordinates
]]
type ChunkCoord = {
	x: number,
	y: number,
	z: number,
}

--[[
	PlayerAction: Action data sent from client to server
]]
type PlayerAction = {
	actionType: "break" | "place",
	position: Vector3,
	blockId: number?,
}

--[[
	SpliceRecipe: A splice combination result
	@field seedA: First seed BlockID
	@field seedB: Second seed BlockID
	@field result: Resulting seed BlockID
]]
type SpliceRecipe = {
	seedA: number,
	seedB: number,
	result: number,
}

--[[
	GrowthDefinition: Defines how a seed grows
	@field seedId: Seed BlockID
	@field spriteId: Sprout BlockID
	@field matureBlockId: Final mature BlockID
	@field growTime: Time in seconds to mature
	@field stages: Array of intermediate growth stages
]]
type GrowthDefinition = {
	seedId: number,
	spriteId: number,
	matureBlockId: number,
	growTime: number,
	stages: { number }?,
}

return Types
