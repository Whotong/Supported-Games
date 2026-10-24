--!strict
-- Grow a Plant: live, read-only Home dashboard. GameId 10768292556.
-- Root PlaceId 74641726785011; verified on Potassium PID 23376 only.
return function(Window: any, _Tabs: any)
	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Workspace = game:GetService("Workspace")
	local RunService = game:GetService("RunService")
	local player = Players.LocalPlayer
	local modules = ReplicatedStorage:FindFirstChild("Modules")
	local plants = ReplicatedStorage:FindFirstChild("Plants")
	local packs = ReplicatedStorage:FindFirstChild("SeedPacks")
	local alive, queued, growing = true, false, false
	local connections: {[any]: boolean} = {}
	local dirty: {[string]: () -> ()} = {}
	local function listen(signal: any, callback: any, group: any?): any
		local connection = signal:Connect(callback)
		connections[connection] = true
		if group then table.insert(group, connection) end
		return connection
	end
	local function disconnect(group: any)
		for _, connection in ipairs(group) do connection:Disconnect() connections[connection] = nil end
		table.clear(group)
	end
	Window:OnClose(function()
		alive = false
		table.clear(dirty)
		for connection in pairs(connections) do connection:Disconnect() end
		table.clear(connections)
	end)
	-- One render per affected panel per event batch; deferred work belongs to
	-- the window and is cancelled by Unload.
	local function queue(key: string, callback: () -> ())
		if not alive then return end
		dirty[key] = callback
		if queued then return end
		queued = true
		Window:_later(0, function()
			queued = false
			local batch = dirty dirty = {}
			for name, render in pairs(batch) do
				local ok, err = pcall(render)
				if not ok then Window:ReportError(name, err) end
			end
		end)
	end
	local function dataModule(folder: string, name: string): any
		local group = modules and modules:FindFirstChild(folder)
		local module = group and group:FindFirstChild(name)
		if not module or not module:IsA("ModuleScript") then return nil end
		local ok, result = pcall(require, module)
		if ok and type(result) == "table" then return result end
		Window:ReportError(name, ok and "Expected a data table" or result)
		return nil
	end
	local mutations = dataModule("Plants", "Mutations")
	local upgrades = dataModule("Core", "UpgradeConfig")
	local petPowers = dataModule("Pets", "PetPowers")
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
	local home = Window:MakeTab("Home")
	local function panel(title: string, order: number, description: string): any
		local section = home:Section({Title = title})
		section.Frame.LayoutOrder = order
		return section:Paragraph({Title = "", Content = description})
	end
	local summary = panel("Economy", 5, "Waiting for your game data…")
	local gardenReport = panel("My garden", 6, "Waiting for your garden…")
	local stockReport = panel("Seed shop", 7, "Waiting for shop stock…")
	local upgradeReport = panel("Next upgrades", 8, "Waiting for upgrade data…")
	local function refreshEconomy()
		local value = moneyValue()
		summary:Set({Content = "Balance  $" .. amount(value and value.Value)
			.. "\nIncome  $" .. amount(player:GetAttribute("IncomeRate")) .. "/s"
			.. "\nGarden  " .. amount(player:GetAttribute("PlantCount")) .. " / " .. amount(player:GetAttribute("MaxPlants"))
			.. "\nInventory  " .. amount(player:GetAttribute("InvCount")) .. " / " .. amount(packs and packs:GetAttribute("MaxInventory"))
			.. "\nWatering speed  ×" .. amount(player:GetAttribute("WaterBoost"))
			.. "    Money multiplier  ×" .. amount(player:GetAttribute("MoneyMulti"))})
	end
	local plantedRoot: any
	local function refreshGarden()
		local now, entries = Workspace:GetServerTimeNow(), {}
		growing = false
		for _, spot in ipairs(plantedRoot and plantedRoot:GetChildren() or {}) do
			if not spot:IsA("BasePart") or spot:GetAttribute("Owner") ~= player.UserId then continue end
			local def = definition(spot:GetAttribute("PlantName") or spot.Name)
			if not def then continue end
			local total = (spot:GetAttribute("SproutDelay") or def:GetAttribute("SproutDelay") or 0)
				+ (spot:GetAttribute("GrowTime") or def:GetAttribute("GrowTime") or 0)
			local born = spot:GetAttribute("PlantedAt")
			local rate = tonumber(spot:GetAttribute("GrowRate")) or 1
			local elapsed = born and ((spot:GetAttribute("RateAt") or born) - born
				+ (now - (spot:GetAttribute("RateAt") or born)) * rate) or nil
			local progress = elapsed and (total > 0 and math.clamp(elapsed / total, 0, 1) or 1)
			growing = growing or (progress ~= nil and progress < 1 and rate > 0)
			local size, mutation = spot:GetAttribute("SizeMult") or 1, spot:GetAttribute("Mutation")
			local multiplier = not mutation and size or nil
			if mutations and type(mutations.Mult) == "function" then multiplier = mutations.Mult(size, mutation) end
			local ratio, baseIncome, moneyMulti = plants:GetAttribute("IncomeStartRatio"), def:GetAttribute("Income"), player:GetAttribute("MoneyMulti")
			local income = progress and multiplier and ratio and baseIncome and moneyMulti
				and baseIncome * multiplier * (ratio + (1 - ratio) * progress) * moneyMulti or nil
			local state = progress and (progress >= 1 and "Grown" or string.format("%.0f%% grown", progress * 100)) or "Growth unknown"
			if elapsed and progress and progress < 1 and rate > 0 then state ..= " · ~" .. amount(math.ceil((total - elapsed) / rate)) .. "s left" end
			table.insert(entries, {Income = income or -1, Text = (def:GetAttribute("DisplayName") or def.Name)
				.. "  ·  $" .. amount(income) .. "/s\n" .. state .. "  ·  size ×" .. amount(size)
				.. (mutation and "  ·  " .. tostring(mutation) or "")})
		end
		table.sort(entries, function(a, b) return a.Income > b.Income end)
		local lines = {}
		for _, entry in ipairs(entries) do table.insert(lines, entry.Text) end
		gardenReport:Set({Content = #lines > 0 and table.concat(lines, "\n\n") or "No owned plants are currently replicated."})
	end
	local stockMap: any
	local restockAt: number?
	local function nativeShop(): any
		local gui = player:FindFirstChildOfClass("PlayerGui")
		local shop = gui and gui:FindFirstChild("SeedShopGui")
		return shop and shop:FindFirstChild("MainFrame")
	end
	local function syncTimer()
		local main = nativeShop()
		local header = main and main:FindFirstChild("Header")
		local timer = header and header:FindFirstChild("TimerTxt")
		local minutes, seconds
		if timer then minutes, seconds = timer.Text:match("^New seeds in (%d+):(%d+)") end
		if minutes and seconds and not stockMap then
			restockAt = Workspace:GetServerTimeNow() + tonumber(minutes) * 60 + tonumber(seconds)
		end
	end
	local function refreshStock()
		local main = nativeShop()
		local body = main and main:FindFirstChild("Body")
		local seedList = body and body:FindFirstChild("SeedList")
		local entries = {}
		if packs then for _, pack in ipairs(packs:GetChildren()) do
			local basePrice = pack:GetAttribute("Price")
			if not basePrice then continue end
			local currency = pack:GetAttribute("Currency") or "Money"
			-- Only list packs in this shop, not Halloween/Candy-only catalog items.
			local card = seedList and seedList:FindFirstChild(pack:GetAttribute("Card") or pack.Name)
			local count = stockMap and stockMap[pack:GetAttribute("PackId") or pack.Name]
			if not card and count == nil then continue end
			local tag = card and card:FindFirstChild("StockTag")
			local stock = tag and tag:FindFirstChild("StockTxt")
			local nativePrice = card and card:FindFirstChild("PriceTxt")
			local price = basePrice
			if currency == "Money" and pack:GetAttribute("NoPetBonus") ~= true then
				if petPowers and type(petPowers.Price) == "function" then price = petPowers.Price(player, price)
				else price = nil end
			end
			local priceText = price and ((currency == "Money" and "$" or "") .. amount(price)
				.. (currency ~= "Money" and " " .. currency or "")) or (nativePrice and nativePrice.Text or "Price unknown")
			local stockText = type(count) == "number" and (count > 0 and ("x" .. count .. " Stock") or "NO STOCK")
				or (stock and stock.Text or "Stock unknown")
			table.insert(entries, {Order = pack:GetAttribute("Order") or 999, Text = pack.Name .. "  ·  " .. priceText .. "  ·  " .. stockText})
		end end
		table.sort(entries, function(a, b) return a.Order < b.Order end)
		local remaining = restockAt and math.max(0, math.ceil(restockAt - Workspace:GetServerTimeNow()))
		local lines = {remaining and string.format("Restock in %d:%02d", remaining // 60, remaining % 60) or "Waiting for the seed restock timer…"}
		for _, entry in ipairs(entries) do table.insert(lines, entry.Text) end
		stockReport:Set({Content = #entries > 0 and table.concat(lines, "\n") or "Seed shop stock is not loaded yet."})
	end
	local function refreshUpgrades()
		if not upgrades or type(upgrades.Price) ~= "function" or type(upgrades.Describe) ~= "function" then
			upgradeReport:Set({Content = "Upgrade data is unavailable."}) return
		end
		local lines = {}
		local balance = moneyValue()
		for _, key in ipairs({"Base", "WateringCan", "MoneyMulti"}) do
			local def, level = upgrades.List and upgrades.List[key], player:GetAttribute("Upg" .. key)
			if def and type(level) == "number" then
				if level >= def.Max then table.insert(lines, def.Name .. " · Maximum level")
				else
					local price = upgrades.Price(key, level + 1)
					local afford = price and balance and (balance.Value >= price and " · Affordable" or " · Need $" .. amount(price - balance.Value)) or ""
					table.insert(lines, def.Name .. " → " .. upgrades.Describe(key, level + 1) .. "  ·  $" .. amount(price) .. afford)
				end
			end
		end
		upgradeReport:Set({Content = #lines > 0 and table.concat(lines, "\n") or "Your upgrade levels have not loaded yet."})
	end
	local function economyChanged() queue("Economy", refreshEconomy) queue("Upgrades", refreshUpgrades) end
	local function gardenChanged() queue("Garden", refreshGarden) end
	local function stockChanged() queue("Seed stock", refreshStock) end
	local moneyGroup = {}
	local function watchMoney()
		disconnect(moneyGroup)
		local stats, value = player:FindFirstChild("leaderstats"), moneyValue()
		if stats then listen(stats.ChildAdded, watchMoney, moneyGroup) listen(stats.ChildRemoved, watchMoney, moneyGroup) end
		if value then listen(value:GetPropertyChangedSignal("Value"), economyChanged, moneyGroup) end
		economyChanged()
	end
	for _, attribute in ipairs({"IncomeRate", "PlantCount", "MaxPlants", "InvCount", "WaterBoost", "MoneyMulti", "DataLoaded", "UpgBase", "UpgWateringCan", "UpgMoneyMulti"}) do
		listen(player:GetAttributeChangedSignal(attribute), function()
			economyChanged()
			if attribute == "MoneyMulti" or attribute == "DataLoaded" then gardenChanged() end
		end)
	end
	-- Track each spot separately so removal releases its listeners immediately.
	local spotGroups: {[any]: any} = {}
	local plantedGroup, worldGroup = {}, {}
	local function watchSpot(spot: any)
		if spotGroups[spot] then disconnect(spotGroups[spot]) end
		local group = {} spotGroups[spot] = group
		if not spot:IsA("BasePart") then return end
		listen(spot:GetAttributeChangedSignal("Owner"), function() watchSpot(spot) gardenChanged() end, group)
		if spot:GetAttribute("Owner") == player.UserId then
			for _, key in ipairs({"PlantName", "PlantedAt", "RateAt", "GrowRate", "GrowTime", "SproutDelay", "SizeMult", "Mutation"}) do
				listen(spot:GetAttributeChangedSignal(key), gardenChanged, group)
			end
		end
	end
	local function bindPlanted(root: any)
		disconnect(plantedGroup)
		for spot, group in pairs(spotGroups) do disconnect(group) spotGroups[spot] = nil end
		plantedRoot = root
		if root then
			for _, spot in ipairs(root:GetChildren()) do watchSpot(spot) end
			listen(root.ChildAdded, function(spot: any) watchSpot(spot) gardenChanged() end, plantedGroup)
			listen(root.ChildRemoved, function(spot: any)
				if spotGroups[spot] then disconnect(spotGroups[spot]) spotGroups[spot] = nil end
				gardenChanged()
			end, plantedGroup)
		end
		gardenChanged()
	end
	local function bindWorld(world: any)
		disconnect(worldGroup)
		bindPlanted(world and world:FindFirstChild("Planted"))
		if world then
			listen(world.ChildAdded, function(child: any) if child.Name == "Planted" then bindPlanted(child) end end, worldGroup)
			listen(world.ChildRemoved, function(child: any) if child == plantedRoot then bindPlanted(nil) end end, worldGroup)
		end
	end
	listen(Workspace.ChildAdded, function(child: any) if child.Name == "Plants" then bindWorld(child) end end)
	listen(Workspace.ChildRemoved, function(child: any) if child.Name == "Plants" then bindWorld(nil) end end)
	bindWorld(Workspace:FindFirstChild("Plants"))
	-- Observe native text and replicated definitions, including late/rebuilt UI.
	local function watchTree(root: any, choose: any, changed: any): () -> ()
		local group, items = {}, {}
		local function add(inst: any)
			if items[inst] then disconnect(items[inst]) end
			local itemGroup = {} items[inst] = itemGroup
			choose(inst, itemGroup)
		end
		for _, inst in ipairs(root:GetDescendants()) do add(inst) end
		listen(root.DescendantAdded, function(inst: any) add(inst) changed() end, group)
		listen(root.DescendantRemoving, function(inst: any)
			if items[inst] then disconnect(items[inst]) items[inst] = nil end
			changed()
		end, group)
		return function()
			disconnect(group)
			for inst, itemGroup in pairs(items) do disconnect(itemGroup) items[inst] = nil end
		end
	end
	local stopShop: any
	local function bindShop()
		if stopShop then stopShop() stopShop = nil end
		local main = nativeShop()
		if main then
			stopShop = watchTree(main, function(inst: any, group: any)
				if (inst:IsA("TextLabel") or inst:IsA("TextButton"))
					and (inst.Name == "StockTxt" or inst.Name == "PriceTxt" or inst.Name == "TimerTxt") then
					listen(inst:GetPropertyChangedSignal("Text"), function() syncTimer() stockChanged() end, group)
				end
			end, function() syncTimer() stockChanged() end)
		end
		syncTimer() stockChanged()
	end
	local gui = player:FindFirstChildOfClass("PlayerGui")
	if gui then
		listen(gui.ChildAdded, function(child: any) if child.Name == "SeedShopGui" then bindShop() end end)
		listen(gui.ChildRemoved, function(child: any) if child.Name == "SeedShopGui" then bindShop() end end)
		listen(gui.DescendantAdded, function(child: any)
			if child.Name == "MainFrame" and child.Parent and child.Parent.Name == "SeedShopGui" then bindShop() end
		end)
		listen(gui.DescendantRemoving, function(child: any)
			if child.Name == "MainFrame" and child.Parent and child.Parent.Name == "SeedShopGui" then queue("Shop binding", bindShop) end
		end)
	end
	listen(player.ChildAdded, function(child: any) if child.Name == "leaderstats" then watchMoney() end end)
	listen(player.ChildRemoved, function(child: any) if child.Name == "leaderstats" then watchMoney() end end)
	if plants then
		listen(plants:GetAttributeChangedSignal("IncomeStartRatio"), gardenChanged)
		watchTree(plants, function(inst: any, group: any)
			if inst.Parent and inst.Parent.Parent == plants then
				for _, key in ipairs({"Income", "DisplayName", "GrowTime", "SproutDelay"}) do listen(inst:GetAttributeChangedSignal(key), gardenChanged, group) end
			end
		end, gardenChanged)
	end
	if packs then
		listen(packs:GetAttributeChangedSignal("MaxInventory"), economyChanged)
		watchTree(packs, function(inst: any, group: any)
			if inst.Parent == packs then
				for _, key in ipairs({"Price", "Currency", "NoPetBonus", "Card", "PackId", "Order"}) do listen(inst:GetAttributeChangedSignal(key), stockChanged, group) end
			end
		end, stockChanged)
	end
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local seedShop = remotes and remotes:FindFirstChild("SeedShop")
	if seedShop and seedShop:IsA("RemoteEvent") then
		listen(seedShop.OnClientEvent, function(kind: any, map: any, at: any)
			if kind == "Stock" and type(map) == "table" then
				stockMap = table.clone(map)
				if type(at) == "number" then restockAt = at end
				stockChanged()
			end
		end)
	end
	-- Elapsed time has no change signal. Only countdowns/growing plants need
	-- this clock; no remote requests or gameplay work are performed.
	local seconds = 0
	listen(RunService.Heartbeat, function(delta: number)
		seconds += delta
		if seconds < 1 then return end
		seconds %= 1
		if growing then gardenChanged() end
		if restockAt then stockChanged() end
	end)
	watchMoney()
	bindShop()
	refreshEconomy() refreshGarden() refreshStock() refreshUpgrades()
	Window:SetReady("Live garden dashboard")
end
