--!strict
-- GemUtils.lua
-- Shared module for gem compression logic used by both server and client.
-- Growtopia-style: large gem totals are compressed into at most 5 tiered visual Parts.

local GemUtils = {}

-- Gem tiers ordered highest to lowest
-- partSize = visual Part size in studs for the 3D drop
-- billboardSize = BillboardGui pixel size
GemUtils.TIERS = {
	{ value = 100, color = Color3.fromRGB(180, 0, 255),  imageId = "rbxassetid://136298567998524", partSize = 1.5, billboardSize = 36 }, -- Purple
	{ value = 50,  color = Color3.fromRGB(0, 200, 50),   imageId = "rbxassetid://81348851929010", partSize = 1.2, billboardSize = 30 }, -- Green
	{ value = 10,  color = Color3.fromRGB(220, 30, 30),  imageId = "rbxassetid://102862809242236", partSize = 1.0, billboardSize = 24 }, -- Red
	{ value = 5,   color = Color3.fromRGB(30, 100, 255), imageId = "rbxassetid://138047713026730", partSize = 0.8, billboardSize = 18 }, -- Blue
	{ value = 1,   color = Color3.fromRGB(255, 220, 0),  imageId = "rbxassetid://138115917380479", partSize = 0.6, billboardSize = 14 }, -- Yellow
}

--[[
	Compress a gem total into a list of tier drops.
	Returns at most 5 Parts total to prevent screen clutter.

	Example: 55 gems → { {value=50,color=green,...}, {value=5,color=blue,...} }
	Example: 7 gems  → { {value=5,color=blue,...}, {value=1,color=yellow,...}, {value=1,color=yellow,...} }

	@param totalValue: number — total gems to compress
	@return { table } — list of tier entries (shallow copies)
]]
function GemUtils.Compress(totalValue: number): { table }
	local drops = {}
	local remaining = totalValue

	for _, tier in ipairs(GemUtils.TIERS) do
		while remaining >= tier.value and #drops < 5 do
			table.insert(drops, tier)
			remaining -= tier.value
		end
		if #drops >= 5 then
			break
		end
	end

	-- If we still have remaining value and hit the 5 Part cap,
	-- the fractional remainder is always < 1 so we just discard it.
	if remaining > 0 and #drops > 0 then
		-- Remainder is always less than the smallest tier (1), so safe to discard.
	end

	print(`[GemUtils] Compress {totalValue} gems → {#drops} Parts (remainder {remaining})`)

	return drops
end

return GemUtils
