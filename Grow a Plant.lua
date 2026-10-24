--!strict
-- Grow a Plant: read-only garden/economy tools. GameId 10768292556.
-- Observed root PlaceId 74641726785011, 2026-10-24, Potassium PID 23376.
-- No purchases, selling, planting, watering, hooks, or gameplay remote calls.
return function(Window: any, Tabs: any)
	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Workspace = game:GetService("Workspace")
	local player = Players.LocalPlayer
	local modules = ReplicatedStorage:FindFirstChild("Modules")
	local plants = ReplicatedStorage:FindFirstChild("Plants")
	local packs = ReplicatedStorage:FindFirstChild("SeedPacks")
	local alive = true
	Window:OnClose(function() alive = false end)

	local function dataModule(folder: string, name: string): any
		local group = modules and modules:FindFirstChild(folder)
		local module = group and group:FindFirstChild(name)
		if not module or not module:IsA("ModuleScript") then return nil end
		local ok, result = pcall(require, module)
		if ok and type(result) == "table" then return result end
		Window:ReportError(name, ok and "Expected a data table" or result)
		return nil
	end
	-- These data modules were inspected before integration. Their exports are
	-- already consumed by the game's own economy and plant-collection clients.
	local mutations = dataModule("Plants", "Mutations")
	local upgrades = dataModule("Core", "UpgradeConfig")
	local function amount(value: any): string
		local n = tonumber(value)
		if not n or n ~= n then return "Unknown" end
		local text = string.format("%.2f", n):gsub("0+$", ""):gsub("%.$", "")
		local integer, fraction = text:match("^(%-?%d+)(.*)$")
		return (integer:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")) .. fraction
	end
	local function moneyValue(): any
		local stats = player:FindFirstChild("leaderstats")
		return stats and stats:FindFirstChild("Money")
	end
	local function definition(name: string): any
		if not plants then return nil end
		for _, rarity in ipairs(plants:GetChildren()) do
			if rarity:IsA("Folder") then
				local found = rarity:FindFirstChild(name)
				if found then return found end
			end
		end
		return nil
	end
	local function ownPlants(): {any}
		local result = {}
		local world = Workspace:FindFirstChild("Plants")
		local planted = world and world:FindFirstChild("Planted")
		if planted then
			for _, spot in ipairs(planted:GetChildren()) do
				if spot:IsA("BasePart") and spot:GetAttribute("Owner") == player.UserId then
					table.insert(result, spot)
				end
			end
		end
		return result
	end

	local economy = Tabs.Main:Section({Title = "Economy", Content = "Live values reported by the game."})
	local summary = economy:Paragraph({Title = "Your session", Content = "Reading game data…"})
	local function refreshEconomy()
		if not alive then return end
		local value = moneyValue()
		local income = player:GetAttribute("IncomeRate")
		summary:Set({Content = "Balance  $" .. amount(value and value.Value)
			.. "\nIncome  $" .. amount(income) .. "/s"
			.. "\nGarden  " .. amount(player:GetAttribute("PlantCount")) .. " / " .. amount(player:GetAttribute("MaxPlants"))
			.. "\nInventory  " .. amount(player:GetAttribute("InvCount")) .. " / " .. amount(packs and packs:GetAttribute("MaxInventory"))
			.. "\nWatering speed  ×" .. amount(player:GetAttribute("WaterBoost"))
			.. "    Money multiplier  ×" .. amount(player:GetAttribute("MoneyMulti"))})
	end
	economy:Button({Id = "EconomyRefresh", Title = "Refresh economy", Content = "Read your current balance, income, and capacity.", Callback = refreshEconomy})
	local watchedMoney: any
	local function watchMoney()
		local value = moneyValue()
		if value and value ~= watchedMoney then
			watchedMoney = value
			Window:Connect(value:GetPropertyChangedSignal("Value"), refreshEconomy)
		end
		refreshEconomy()
	end
	local stats = player:FindFirstChild("leaderstats")
	if stats then Window:Connect(stats.ChildAdded, watchMoney) end
	Window:Connect(player.ChildAdded, function(child: any)
		if child.Name == "leaderstats" then Window:Connect(child.ChildAdded, watchMoney) watchMoney() end
	end)
	for _, attribute in ipairs({"IncomeRate", "PlantCount", "MaxPlants", "InvCount", "WaterBoost", "MoneyMulti", "DataLoaded"}) do
		Window:Connect(player:GetAttributeChangedSignal(attribute), refreshEconomy)
	end
	watchMoney()

	local garden = Tabs.Main:Section({Title = "My garden", Content = "Only your planted flowers. Growth and income are estimates from replicated state."})
	local gardenReport = garden:Paragraph({Title = "Plant report", Content = "Select Inspect garden to read the current plants."})
	local function inspectGarden()
		local now = Workspace:GetServerTimeNow()
		local entries = {}
		for _, spot in ipairs(ownPlants()) do
			local def = definition(spot:GetAttribute("PlantName") or spot.Name)
			if def then
				local total = (spot:GetAttribute("SproutDelay") or def:GetAttribute("SproutDelay") or 0)
					+ (spot:GetAttribute("GrowTime") or def:GetAttribute("GrowTime") or 0)
				local born = spot:GetAttribute("PlantedAt")
				local rate = tonumber(spot:GetAttribute("GrowRate")) or 1
				local elapsed = born and ((spot:GetAttribute("RateAt") or born) - born
					+ (now - (spot:GetAttribute("RateAt") or born)) * rate) or nil
				local progress = elapsed and (total > 0 and math.clamp(elapsed / total, 0, 1) or 1)
				local size = spot:GetAttribute("SizeMult") or 1
				local mutation = spot:GetAttribute("Mutation")
				local multiplier = not mutation and size or nil
				if mutations and type(mutations.Mult) == "function" then multiplier = mutations.Mult(size, mutation) end
				local startRatio = plants:GetAttribute("IncomeStartRatio")
				local baseIncome = def:GetAttribute("Income")
				local moneyMulti = player:GetAttribute("MoneyMulti")
				local income = progress and multiplier and startRatio and baseIncome and moneyMulti
					and baseIncome * multiplier * (startRatio + (1 - startRatio) * progress) * moneyMulti or nil
				local state = progress and (progress >= 1 and "Grown" or string.format("%.0f%% grown", progress * 100)) or "Growth unknown"
				if elapsed and progress and progress < 1 and rate > 0 then state ..= " · ~" .. amount(math.ceil((total - elapsed) / rate)) .. "s left" end
				table.insert(entries, {Income = income or -1, Text = (def:GetAttribute("DisplayName") or def.Name)
					.. "  ·  $" .. amount(income) .. "/s\n" .. state .. "  ·  size ×" .. amount(size)
					.. (mutation and "  ·  " .. tostring(mutation) or "")})
			end
		end
		table.sort(entries, function(a, b) return a.Income > b.Income end)
		local lines = {}
		for _, entry in ipairs(entries) do table.insert(lines, entry.Text) end
		gardenReport:Set({Content = #lines > 0 and table.concat(lines, "\n\n") or "No owned plants are currently replicated. Try again after your base loads."})
	end
	garden:Button({Id = "InspectGarden", Title = "Inspect garden", Content = "List your plants by estimated income, with growth and size.", Callback = inspectGarden})

	local shop = Tabs.Main:Section({Title = "Seed shop", Content = "Prices and stock from the game's shop cards. This does not buy anything."})
	local stockReport = shop:Paragraph({Title = "Current stock", Content = "Select Check seed stock to read the shop."})
	local function inspectStock()
		local gui = player:FindFirstChildOfClass("PlayerGui")
		local nativeShop = gui and gui:FindFirstChild("SeedShopGui")
		local main = nativeShop and nativeShop:FindFirstChild("MainFrame")
		local body = main and main:FindFirstChild("Body")
		local seedList = body and body:FindFirstChild("SeedList")
		if not seedList or not packs then stockReport:Set({Content = "Seed shop cards are not loaded yet."}) return end
		local entries = {}
		for _, pack in ipairs(packs:GetChildren()) do
			local currency = pack:GetAttribute("Currency") or "Money"
			local card = seedList:FindFirstChild(pack:GetAttribute("Card") or pack.Name)
			if pack:GetAttribute("Price") and card then
				local tag = card:FindFirstChild("StockTag")
				local stock = tag and tag:FindFirstChild("StockTxt")
				local price = card:FindFirstChild("PriceTxt")
				table.insert(entries, {Order = pack:GetAttribute("Order") or 999, Text = pack.Name .. "  ·  "
					.. (price and price.Text or "Price unknown") .. "  ·  " .. (stock and stock.Text or "Stock unknown")
					.. (currency ~= "Money" and "  (" .. currency .. ")" or "")})
			end
		end
		table.sort(entries, function(a, b) return a.Order < b.Order end)
		local lines = {}
		local header = main:FindFirstChild("Header")
		local timer = header and header:FindFirstChild("TimerTxt")
		if timer then table.insert(lines, timer.Text) end
		for _, entry in ipairs(entries) do table.insert(lines, entry.Text) end
		stockReport:Set({Content = #entries > 0 and table.concat(lines, "\n") or "No seed shop cards are available yet."})
	end
	shop:Button({Id = "SeedStock", Title = "Check seed stock", Content = "Read current prices, availability, and the restock timer.", Callback = inspectStock})

	local upgrade = Tabs.Main:Section({Title = "Upgrades", Content = "Preview the next upgrade without purchasing it."})
	local upgradeReport = upgrade:Paragraph({Title = "Next upgrades", Content = "Select Preview upgrades to compare your next levels."})
	upgrade:Button({Id = "UpgradePreview", Title = "Preview upgrades", Content = "Read your next base, watering, and income upgrades.", Callback = function()
		if not upgrades or type(upgrades.Price) ~= "function" or type(upgrades.Describe) ~= "function" then
			upgradeReport:Set({Content = "Upgrade data is unavailable."}) return
		end
		local lines = {}
		for _, key in ipairs({"Base", "WateringCan", "MoneyMulti"}) do
			local def = upgrades.List and upgrades.List[key]
			local level = player:GetAttribute("Upg" .. key)
			if def and type(level) == "number" then
				if level >= def.Max then table.insert(lines, def.Name .. " · Maximum level")
				else
					local price = upgrades.Price(key, level + 1)
					table.insert(lines, def.Name .. " → " .. upgrades.Describe(key, level + 1) .. "  ·  $" .. amount(price))
				end
			end
		end
		upgradeReport:Set({Content = #lines > 0 and table.concat(lines, "\n") or "Your upgrade levels have not loaded yet."})
	end})
	Window:SetReady("Garden tools ready · economy and plant reports")
end
