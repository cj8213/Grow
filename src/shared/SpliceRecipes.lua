-- SpliceRecipes.lua
-- All splice recipe pairs for GrowRoblox
-- Recipe key: "minId_maxId" -> resultId
-- All recipes are symmetric (A+B = B+A)

local SpliceRecipes = {}

-- Internal recipe lookup table
local recipes = {}

-- Helper: register a recipe
local function recipe(seedA: number, seedB: number, result: number)
	local key
	if seedA < seedB then
		key = seedA .. "_" .. seedB
	else
		key = seedB .. "_" .. seedA
	end
	recipes[key] = result
end

--[[
	=== TIER 2 RECIPES ===
	From base world items (Dirt=1, Rock=2, CaveBg=3, Lava=4)
]]

-- Dirt + Cave Background = Door (ID 8)
recipe(1, 3, 8)

-- Dirt + Rock = Grass (ID 7)
recipe(1, 2, 7)

-- Dirt + Lava = Wood Block (ID 9)
recipe(1, 4, 9)

-- Rock + Lava = Glass Pane (ID 10)
recipe(2, 4, 10)

-- Cave Background + Rock = Sign (ID 11)
recipe(2, 3, 11)

-- Lava + Cave Background = Lava Rock (ID 12)
recipe(3, 4, 12)

--[[
	=== TIER 3 RECIPES ===
	From Tier 2 items
]]

-- Grass(7) + Door(8) = Wooden Background(13)
recipe(7, 8, 13)

-- Door(8) + Sign(11) = Pointy Sign(14)
recipe(8, 11, 14)

-- Door(8) + Dirt(1) = Crappy Sign(15)
recipe(1, 8, 15)

-- Grass(7) + Dirt(1) = Daisy(16)
recipe(1, 7, 16)

-- Wood Block(9) + Grass(7) = Wooden Platform(17)
recipe(7, 9, 17)

-- Rock(2) + Door(8) = Rock Background(18)
recipe(2, 8, 18)

-- Rock(2) + Grass(7) = Bricks(19)
recipe(2, 7, 19)

-- Grass(7) + Lava(4) = Rose(20)
recipe(4, 7, 20)

-- Cave Background(3) + Grass(7) = Mushroom(22)
recipe(3, 7, 22)

-- Dirt(1) + Wood Block(9) = Cargo Shorts(25)
recipe(1, 9, 25)

-- Dirt(1) + Glass Pane(10) = Amber Glass(23)
recipe(1, 10, 23)

-- Sign(11) + Lava(4) = Torch(21)
recipe(4, 11, 21)

-- Dirt(1) + Sign(11) = Super Crate Box(24)
recipe(1, 11, 24)

--[[
	=== TIER 4 RECIPES (Sugar Cane + Window) ===
]]

-- Sugar Cane(29) + Window(30) = Sugar Window (future)
-- Add more as new items are introduced

--[[
	=== PUBLIC API ===
]]

function SpliceRecipes.GetResult(seedA: number, seedB: number): number?
	local key
	if seedA < seedB then
		key = seedA .. "_" .. seedB
	else
		key = seedB .. "_" .. seedA
	end
	return recipes[key]
end

function SpliceRecipes.CanSplice(seedA: number, seedB: number): boolean
	return SpliceRecipes.GetResult(seedA, seedB) ~= nil
end

function SpliceRecipes.GetAllRecipes(): { { seedA: number, seedB: number, result: number } }
	local list = {}
	for key, result in pairs(recipes) do
		local a, b = string.match(key, "(%d+)_(%d+)")
		table.insert(list, {
			seedA = tonumber(a),
			seedB = tonumber(b),
			result = result,
		})
	end
	return list
end

-- Register tier 1 seeds for backwards compatibility
-- Dirt Seed(101), Rock Seed(102), CaveBg Seed(103), Lava Seed(104)

local recipeCount = 0
for _ in pairs(recipes) do recipeCount += 1 end
print(`[SpliceRecipes] Loaded {recipeCount} recipes`)

return SpliceRecipes
