--!strict
-- Grow a Plant: live Home dashboard and opt-in Shops. GameId 10768292556.
-- Root PlaceId 74641726785011; current live-test account recorded in game notes.
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
	local shopsChanged: (() -> ())?
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
	local function economyChanged()
		queue("Economy", refreshEconomy) queue("Upgrades", refreshUpgrades)
		if shopsChanged then shopsChanged() end
	end
	local function gardenChanged() queue("Garden", refreshGarden) end
	local function stockChanged() queue("Seed stock", refreshStock) if shopsChanged then shopsChanged() end end
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
	local function watchTree(root: any, choose: any, changed: any, relevant: any?): () -> ()
		local group, items = {}, {}
		local function add(inst: any)
			if items[inst] then disconnect(items[inst]) end
			local itemGroup = {} items[inst] = itemGroup
			choose(inst, itemGroup)
		end
		for _, inst in ipairs(root:GetDescendants()) do add(inst) end
		listen(root.DescendantAdded, function(inst: any) add(inst) if not relevant or relevant(inst) then changed() end end, group)
		listen(root.DescendantRemoving, function(inst: any)
			if items[inst] then disconnect(items[inst]) items[inst] = nil end
			if not relevant or relevant(inst) then changed() end
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

	-- Shops are opt-in. Merely loading, navigating, or configuring does no
	-- buying/listing/selling. Only these four owning toggles can start work.
	local shops = Window:MakeTab("Shops")
	local eggs, pets = ReplicatedStorage:FindFirstChild("Eggs"), ReplicatedStorage:FindFirstChild("Pets")
	local eggRemote = remotes and remotes:FindFirstChild("EggShop")
	local sellRemote = remotes and remotes:FindFirstChild("SellItems")
	local teleportRemote = remotes and remotes:FindFirstChild("Teleport")
	local config = {Seeds = {}, Eggs = {}, PlantRarities = {}, PetRarities = {}, UseIncome = false, IncomeCap = 0, Reserve = 0, SeedLimit = 0, EggLimit = 0, TravelToSell = false}
	local handles, actions, enabled, versions, confirmed = {}, {}, {}, {}, {}
	local buyIds = {"AutoBuySeedPacks", "AutoBuyEggs"}
	local plantId, petId = "AutoSellPlants", "AutoSellPets"
	local inventoryVersion, scannedVersion = 0, -1
	local eggStock: any
	local pending: any
	local travel: any
	local travelTimeout: any
	local saleWasNear: boolean?
	local worker: any
	local timer: any
	local workingId: string?
	local requests: {[any]: boolean} = {}
	local lastRequest = -math.huge
	local again = false
	local wake: any
	local configured: any
	local function anyEnabled(): boolean
		for _, value in pairs(enabled) do if value then return true end end
		return false
	end
	local function valid(id: string, version: number): boolean
		return alive and enabled[id] == true and versions[id] == version
	end
	local function status(id: string, text: string)
		local action = actions[id]
		if action and action.Status ~= text then action:SetStatus(text) end
	end
	local function stop(id: string, text: string?)
		enabled[id] = false versions[id] = (versions[id] or 0) + 1
		if actions[id] then actions[id]:Sync(false, text or "Off") end
	end
	local function clearTravel()
		travel = nil
		if travelTimeout then
			local ok, err = pcall(task.cancel, travelTimeout)
			if not ok then Window:ReportError("Shops cleanup", err) end
			Window._tasks[travelTimeout] = nil
			travelTimeout = nil
		end
	end
	local function cancelWorker()
		if worker and worker ~= coroutine.running() then
			local ok, err = pcall(task.cancel, worker)
			if not ok then Window:ReportError("Shops cleanup", err) end
			Window._tasks[worker] = nil
		end
		worker = nil
		for thread in pairs(requests) do
			local ok, err = pcall(task.cancel, thread)
			if not ok then Window:ReportError("Shops request cleanup", err) end
			requests[thread] = nil
		end
	end
	local function changed()
		inventoryVersion += 1
		if configured then
			for id, action in pairs(actions) do
				local available, reason = configured(id)
				if available then reason = nil end
				if action.Available ~= available or action.Reason ~= reason then action:SetAvailable(available, reason) end
			end
		end
		if wake then wake() end
	end
	configured = function(id: string): (boolean, string?)
		if player:GetAttribute("DataLoaded") == false then return false, "Waiting for game data" end
		if id == buyIds[1] then
			if not seedShop or not seedShop:IsA("RemoteEvent") then return false, "Seed shop unavailable" end
			return #config.Seeds > 0, "Select at least one seed pack"
		elseif id == buyIds[2] then
			if not eggRemote or not eggRemote:IsA("RemoteEvent") then return false, "Egg shop unavailable" end
			return #config.Eggs > 0, "Select at least one egg"
		end
		if not sellRemote or not sellRemote:IsA("RemoteFunction") then return false, "Sell menu unavailable" end
		if id == plantId then return #config.PlantRarities > 0 or config.UseIncome, "Select rarities or enable an income limit" end
		return #config.PetRarities > 0, "Select at least one pet rarity"
	end
	local function makeToggle(section: any, id: string, title: string, description: string)
		actions[id] = section:Toggle({Id = id, Title = title, Content = description, Default = false,
			CanActivate = function() return configured(id) end,
			Callback = function(on: boolean)
				versions[id] = (versions[id] or 0) + 1
				enabled[id] = on
				if on then confirmed[id] = 0 inventoryVersion += 1 status(id, "Waiting for matching items")
				else
					if workingId == id then cancelWorker() workingId = nil end
					if not enabled[plantId] and not enabled[petId] then clearTravel() end
					status(id, "Off")
				end
				if wake then wake() end
			end})
	end
	local function numberInput(section: any, key: string, title: string, description: string)
		handles[key] = section:TextInput({Title = title, Content = description, Default = "0", Callback = function(text: string)
			local value = tonumber((text:gsub(",", "")))
			assert(value and value == value and value >= 0 and value < math.huge, "Enter a non-negative number")
			config[key] = key:find("Limit") and math.floor(value) or value
			changed()
		end})
	end
	local function rarityOptions(root: any): {string}
		local list = {}
		for _, item in ipairs(root and root:GetChildren() or {}) do
			if item:IsA("Folder") and type(item:GetAttribute("Order")) == "number" then table.insert(list, item) end
		end
		table.sort(list, function(a, b) return a:GetAttribute("Order") < b:GetAttribute("Order") end)
		local result = {} for _, item in ipairs(list) do table.insert(result, item.Name) end return result
	end
	local function catalog(isEgg: boolean): {any}
		local result = {}
		for _, item in ipairs(isEgg and (eggs and eggs:GetDescendants() or {}) or (packs and packs:GetChildren() or {})) do
			if type(item:GetAttribute("Price")) == "number" and (not isEgg or item:IsA("Model"))
				and (item:GetAttribute("Currency") or "Money") == "Money" and item:GetAttribute("Shop") ~= "Halloween" then
				table.insert(result, item)
			end
		end
		table.sort(result, function(a, b) return (a:GetAttribute("Order") or 999) < (b:GetAttribute("Order") or 999) end)
		return result
	end
	local function names(list: {any}): {string}
		local result = {} for _, item in ipairs(list) do table.insert(result, item.Name) end return result
	end
	local function selection(section: any, key: string, title: string, options: {string})
		handles[key] = section:Dropdown({Title = title, Multi = true, Options = options, Default = {}, Callback = function(values: {string})
			config[key] = table.clone(values)
			-- Recheck a changed filter after an outstanding read completes.
			for id in pairs(versions) do versions[id] += 1 end
			changed()
		end})
	end
	local limits = shops:Section({Title = "Purchase limits", Expanded = true})
	numberInput(limits, "Reserve", "Keep at least ($)", "Both buyers respect this shared balance reserve. 0 keeps no reserve.")
	local seedsSection = shops:Section({Title = "Seed packs", Expanded = true})
	makeToggle(seedsSection, buyIds[1], "Auto buy selected seed packs", "Buy in-stock selections with game Money. Waits for inventory confirmation after each request.")
	selection(seedsSection, "Seeds", "Selected seed packs", names(catalog(false)))
	numberInput(seedsSection, "SeedLimit", "Seed packs per activation", "0 keeps buying while enabled. A positive limit stops after confirmed purchases.")
	local accessSection = shops:Section({Title = "Sale access", Expanded = true})
	handles.TravelToSell = accessSection:Toggle({Title = "Travel to sell shop", Content = "Both sellers can use the game's Sell teleport when matching items exist. Stays at the shop. Off waits for you to arrive.", Setting = true, Default = false,
		Callback = function(value: boolean) config.TravelToSell = value changed() end})
	local plantsSection = shops:Section({Title = "Sell plants", Expanded = true})
	makeToggle(plantsSection, plantId, "Auto sell matching plants", "At the Sell shop: inventory plants matching selected rarity OR enabled income limit. Favorites stay protected.")
	selection(plantsSection, "PlantRarities", "Plant rarities to sell", rarityOptions(plants))
	handles.UseIncome = plantsSection:Toggle({Title = "Use income limit", Setting = true, Default = false, Callback = function(value: boolean)
		config.UseIncome = value versions[plantId] = (versions[plantId] or 0) + 1 changed()
	end})
	numberInput(plantsSection, "IncomeCap", "Sell at or below ($/s)", "Estimated planted income, including growth, size, mutation, and your money multiplier.")
	local eggsSection = shops:Section({Title = "Eggs", Expanded = true})
	makeToggle(eggsSection, buyIds[2], "Auto buy selected eggs", "Buy selected in-stock eggs with game Money. Eggs remain unhatched.")
	selection(eggsSection, "Eggs", "Selected eggs", names(catalog(true)))
	numberInput(eggsSection, "EggLimit", "Eggs per activation", "0 keeps buying while enabled. A positive limit stops after confirmed purchases.")
	local petsSection = shops:Section({Title = "Sell pets", Expanded = true})
	makeToggle(petsSection, petId, "Auto sell selected pet rarities", "At the Sell shop: matching inventory pets. Favorites and equipped pets are kept.")
	selection(petsSection, "PetRarities", "Pet rarities to sell", rarityOptions(pets))
	petsSection:Toggle({Id = "AutoSellEggs", Title = "Auto sell unhatched eggs", Available = false,
		UnavailableReason = "No egg-selling action is exposed by the native sell system", Default = false})

	local function heldCount(isEgg: boolean, name: string): number
		local count = 0
		for _, root in ipairs({player:FindFirstChildOfClass("Backpack"), player.Character}) do
			if root then for _, tool in ipairs(root:GetChildren()) do
				if tool:IsA("Tool") and (isEgg and tool:GetAttribute("ToolType") == "Egg" and tool:GetAttribute("EggName") == name
					or not isEgg and tool:GetAttribute("PackId") == name) then count += tonumber(tool:GetAttribute("Count")) or 1 end
			end end
		end
		return count
	end
	local function currentStock(item: any, isEgg: boolean): number?
		local map = isEgg and eggStock or stockMap
		local value = map and map[isEgg and item.Name or (item:GetAttribute("PackId") or item.Name)]
		if type(value) == "number" then return value end
		local main = nativeShop()
		local body = main and main:FindFirstChild(isEgg and "EggBody" or "Body")
		local list = body and body:FindFirstChild(isEgg and "EggList" or "SeedList")
		local card = list and list:FindFirstChild(item:GetAttribute("Card") or item.Name)
		local tag = card and card:FindFirstChild("StockTag")
		local text = tag and tag:FindFirstChild("StockTxt")
		if not text then return nil end
		if text.Text == "NO STOCK" then return 0 end
		return tonumber(text.Text:match("^x(%d+) Stock$"))
	end
	local function waitGap(id: string, version: number): boolean
		local gap = 0.5 - (Workspace:GetServerTimeNow() - lastRequest)
		if gap > 0 then task.wait(gap) end
		return valid(id, version)
	end
	local function invoke(id: string, version: number, ...: any): any
		if not waitGap(id, version) then return nil end
		lastRequest = Workspace:GetServerTimeNow()
		local args, done, success, result = table.pack(...), false, false, nil
		local thread = task.defer(function()
			success, result = pcall(sellRemote.InvokeServer, sellRemote, table.unpack(args, 1, args.n))
			done = true
		end)
		requests[thread] = true
		local started = Workspace:GetServerTimeNow()
		while not done and valid(id, version) and Workspace:GetServerTimeNow() - started < 8 do task.wait(0.05) end
		requests[thread] = nil
		if not done then
			local cancelled, err = pcall(task.cancel, thread)
			if not cancelled then error(err) end
			if not valid(id, version) then return nil end
			error("Shop request timed out; automation paused")
		end
		if not success then error(result) end
		if not valid(id, version) then return nil end
		return result
	end
	local function protected(entry: any, category: string): boolean
		if entry.fav == true or entry.eq == true then return true end
		for _, root in ipairs({player:FindFirstChildOfClass("Backpack"), player.Character}) do
			if root then for _, tool in ipairs(root:GetChildren()) do
				if tool:IsA("Tool") and tool:GetAttribute(category == "Plants" and "ItemId" or "PetId") == entry.id then
					if tool:GetAttribute("Favorite") == true or category == "Pets" and tool.Parent == player.Character then return true end
				end
			end end
		end
		return false
	end
	local function plantIncome(entry: any): number?
		local def = type(entry.plant) == "string" and definition(entry.plant)
		if not def or type(entry.elapsed) ~= "number" or type(entry.size) ~= "number" then return nil end
		local base, ratio, multi = def:GetAttribute("Income"), plants:GetAttribute("IncomeStartRatio"), player:GetAttribute("MoneyMulti")
		if type(base) ~= "number" or type(ratio) ~= "number" or type(multi) ~= "number" then return nil end
		local total = (def:GetAttribute("SproutDelay") or 0) + (def:GetAttribute("GrowTime") or 0)
		local size = not entry.mut and entry.size or nil
		if mutations and type(mutations.Mult) == "function" then size = mutations.Mult(entry.size, entry.mut) end
		if not size then return nil end
		return base * size * (ratio + (1 - ratio) * (total > 0 and math.clamp(entry.elapsed / total, 0, 1) or 1)) * multi
	end
	local function saleFailure(result: any, category: string, count: number): string
		local detail = {category .. " sale declined by server", tostring(count) .. " item(s) requested"}
		if type(result) == "table" then
			table.insert(detail, "ok=" .. tostring(result.ok))
			for _, key in ipairs({"message", "error", "reason", "code"}) do
				local value = result[key]
				if type(value) == "string" or type(value) == "number" then table.insert(detail, key .. "=" .. tostring(value):sub(1, 200)) end
			end
		else table.insert(detail, "response=" .. tostring(result):sub(1, 200)) end
		return table.concat(detail, "; ") .. ". Selling paused; no automatic retry."
	end
	local function saleAccess(): (boolean, string, boolean)
		local lobby = Workspace:FindFirstChild("LobbyFolder")
		local shop = lobby and lobby:FindFirstChild("ShopSell")
		local part = shop and shop:FindFirstChild("ProximityPromptPart")
		local prompt = part and part:FindFirstChildOfClass("ProximityPrompt")
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if not root then return false, "Waiting for character", false end
		if not part or not part:IsA("BasePart") or not prompt then return false, "Waiting for Sell shop", false end
		local distance = (root.Position - part.Position).Magnitude
		return distance <= prompt.MaxActivationDistance, "Move near Sell shop · " .. tostring(math.ceil(distance)) .. " studs", true
	end
	local function salePositionChanged()
		if not enabled[plantId] and not enabled[petId] then saleWasNear = nil return end
		local near, reason = saleAccess()
		if near and travel then clearTravel() end
		if not near then
			for _, id in ipairs({plantId, petId}) do
				if enabled[id] then status(id, travel and "Travelling to Sell shop" or reason) end
			end
		end
		if near ~= saleWasNear then saleWasNear = near inventoryVersion += 1 wake() end
	end
	local function ensureSaleAccess(id: string, version: number): boolean
		local near, reason, canTravel = saleAccess()
		if near then clearTravel() return true end
		if travel then status(id, "Travelling to Sell shop") return false end
		if not config.TravelToSell or not canTravel then status(id, reason) return false end
		if not teleportRemote or not teleportRemote:IsA("RemoteEvent") then status(id, "Sell teleport unavailable · move to the shop") return false end
		if not waitGap(id, version) then return false end
		-- Arrival or settings can change while the shared request gap elapses.
		if saleAccess() then return true end
		if not config.TravelToSell then return false end
		local order = {}
		travel = order saleWasNear = false lastRequest = Workspace:GetServerTimeNow()
		status(id, "Travelling to Sell shop")
		travelTimeout = Window:_later(8, function()
			travelTimeout = nil
			if travel ~= order then return end
			travel = nil
			if saleAccess() then inventoryVersion += 1 wake() return end
			stop(plantId, "Paused · Sell teleport unconfirmed") stop(petId, "Paused · Sell teleport unconfirmed")
			Window:ReportError("Shops", "Sell teleport did not arrive. Sellers paused without retrying it.")
		end)
		teleportRemote:FireServer("Sell")
		return false
	end
	local function sellMatching(id: string, category: string, key: string, revision: number)
		if not enabled[id] then return end
		workingId = id
		local version = versions[id]
		local near, reason = saleAccess()
		if not near and not config.TravelToSell then status(id, reason) return end
		local result = invoke(id, version, "List")
		if not valid(id, version) or not result then return end
		assert(type(result) == "table" and type(result[key]) == "table", "Unexpected sell inventory response")
		if inventoryVersion ~= revision then again = true return end
		local ids = {}
		for _, entry in ipairs(result[key]) do
			if type(entry) == "table" and type(entry.id) == "string" and not protected(entry, category) then
				local def = category == "Plants" and type(entry.plant) == "string" and definition(entry.plant) or nil
				local rarity = category == "Plants" and def and def:GetAttribute("Rarity") or category == "Pets" and entry.rarity
				local picked = table.find(category == "Plants" and config.PlantRarities or config.PetRarities, rarity) ~= nil
				local income = category == "Plants" and config.UseIncome and plantIncome(entry) or nil
				if picked or income and income <= config.IncomeCap then table.insert(ids, entry.id) end
			end
		end
		if #ids == 0 then status(id, "Waiting for matching inventory") return end
		if not ensureSaleAccess(id, version) then return end
		-- Filters/inventory may change while the global request gap elapses.
		if not waitGap(id, version) then return end
		if inventoryVersion ~= revision then again = true return end
		if not saleAccess() then status(id, "Move near Sell shop") return end
		local sold = invoke(id, version, "Sell", category, ids)
		if not valid(id, version) then return end
		if type(sold) ~= "table" or sold.ok ~= true then error(saleFailure(sold, category, #ids), 0) end
		status(id, "Sale confirmed · $" .. amount(sold.total))
	end
	local buyTurn = 1
	local function effectivePrice(item: any, isEgg: boolean): number?
		local price = item:GetAttribute("Price")
		if isEgg or item:GetAttribute("NoPetBonus") ~= true then
			if not petPowers or type(petPowers.Price) ~= "function" then return nil end
			price = petPowers.Price(player, price)
		end
		return type(price) == "number" and price > 0 and price < math.huge and price or nil
	end
	local function tryBuy(id: string, isEgg: boolean): boolean
		if not enabled[id] then return false end
		local limit = isEgg and config.EggLimit or config.SeedLimit
		if limit > 0 and (confirmed[id] or 0) >= limit then stop(id, "Purchase limit reached") return false end
		local count, cap = player:GetAttribute(isEgg and "PetInvCount" or "InvCount"), packs and packs:GetAttribute(isEgg and "MaxPetInventory" or "MaxInventory")
		if type(count) ~= "number" or type(cap) ~= "number" then status(id, "Waiting for inventory data") return false end
		if count >= cap then status(id, "Inventory full · waiting for space") return false end
		local choices, foundStock, affordable = isEgg and config.Eggs or config.Seeds, false, false
		for _, item in ipairs(catalog(isEgg)) do
			if table.find(choices, item.Name) then
				local stock = currentStock(item, isEgg)
				if stock and stock > 0 then
					foundStock = true
					local price = effectivePrice(item, isEgg)
					local balance = moneyValue()
					if balance and type(price) == "number" and price > 0 and balance.Value - price >= config.Reserve then
						affordable = true workingId = id
						local version = versions[id]
						if not waitGap(id, version) then return false end
						-- Recheck every precondition at the actual send boundary.
						balance = moneyValue() stock = currentStock(item, isEgg)
						price = effectivePrice(item, isEgg)
						count = player:GetAttribute(isEgg and "PetInvCount" or "InvCount")
						cap = packs:GetAttribute(isEgg and "MaxPetInventory" or "MaxInventory")
						limit = isEgg and config.EggLimit or config.SeedLimit
						if not price or not balance or balance.Value - price < config.Reserve or not stock or stock <= 0 or type(count) ~= "number" or type(cap) ~= "number" or count >= cap
							or limit > 0 and (confirmed[id] or 0) >= limit then return false end
						local name = isEgg and item.Name or (item:GetAttribute("PackId") or item.Name)
						pending = {Id = id, IsEgg = isEgg, Name = name, Before = heldCount(isEgg, name), At = Workspace:GetServerTimeNow()}
						local remote = isEgg and eggRemote or seedShop
						lastRequest = pending.At
						local ok, err = pcall(remote.FireServer, remote, "Buy", name)
						if not ok then pending = nil error(err) end
						status(id, "Purchase requested · waiting for inventory")
						return true
					end
				end
			end
		end
		status(id, not foundStock and "Waiting for selected stock" or not affordable and "Waiting for money above reserve" or "Waiting")
		return false
	end
	local function process()
		if pending then
			local order = pending
			if heldCount(order.IsEgg, order.Name) > order.Before then
				confirmed[order.Id] = (confirmed[order.Id] or 0) + 1
				status(order.Id, "Confirmed purchases: " .. confirmed[order.Id])
				pending = nil
				local limit = order.IsEgg and config.EggLimit or config.SeedLimit
				if enabled[order.Id] and limit > 0 and confirmed[order.Id] >= limit then stop(order.Id, "Purchase limit reached") end
			elseif Workspace:GetServerTimeNow() - order.At >= 8 then
				pending = nil
				stop(buyIds[1], "Paused · purchase unconfirmed") stop(buyIds[2], "Paused · purchase unconfirmed")
				Window:ReportError("Shops", "No inventory confirmation for the purchase. Buyers paused without retrying it.")
			else return end
		end
		if inventoryVersion ~= scannedVersion then
			local revision = inventoryVersion
			sellMatching(plantId, "Plants", "plants", revision)
			sellMatching(petId, "Pets", "pets", revision)
			if revision == inventoryVersion then scannedVersion = revision end
		end
		if travel then return end
		for offset = 0, 1 do
			local index = (buyTurn + offset - 1) % 2 + 1
			if tryBuy(buyIds[index], index == 2) then buyTurn = index % 2 + 1 return end
		end
	end
	wake = function(delay: number?)
		if not alive or not anyEnabled() then return end
		if worker then again = true return end
		if timer then return end
		timer = Window:_later(math.max(delay or 0.2, 0.5 - (Workspace:GetServerTimeNow() - lastRequest)), function()
			timer = nil
			if not anyEnabled() then return end
			worker = coroutine.running() again = false
			local current = worker
			local ok, err = pcall(process)
			if worker == current then worker = nil end
			if not ok then
				if workingId then stop(workingId, "Paused · see Diagnostics") end
				Window:ReportError("Shops", err)
			end
			workingId = nil
			if pending or again then wake(pending and 0.25 or 0.5) end
		end)
	end
	shopsChanged = function() wake() end
	listen(player:GetAttributeChangedSignal("PetInvCount"), changed)
	listen(player:GetAttributeChangedSignal("InvCount"), changed)
	listen(player:GetAttributeChangedSignal("MoneyMulti"), changed)
	local roots: {[string]: any} = {}
	local function bindInventory(key: string, root: any)
		if roots[key] then roots[key]() roots[key] = nil end
		local function relevant(inst: any): boolean return inst:IsA("Tool") or key == "Pets" and inst.Parent == root or key == "Character" and inst.Name == "HumanoidRootPart" end
		if root then roots[key] = watchTree(root, function(inst: any, group: any)
			if key == "Character" and inst.Name == "HumanoidRootPart" then listen(inst:GetPropertyChangedSignal("CFrame"), salePositionChanged, group) end
			if relevant(inst) then
				for _, attribute in ipairs({"Favorite", "Equipped", "Count", "ItemId", "PetId", "ToolType", "PlantName", "Mutation"}) do listen(inst:GetAttributeChangedSignal(attribute), changed, group) end
			end
		end, changed, relevant) end
		changed()
	end
	listen(player.ChildAdded, function(child: any)
		if child:IsA("Backpack") then bindInventory("Backpack", child) elseif child.Name == "PetsOwned" then bindInventory("Pets", child) end
	end)
	listen(player.ChildRemoved, function(child: any)
		if child:IsA("Backpack") then bindInventory("Backpack", nil) elseif child.Name == "PetsOwned" then bindInventory("Pets", nil) end
	end)
	listen(player.CharacterAdded, function(character: any) bindInventory("Character", character) end)
	if teleportRemote and teleportRemote:IsA("RemoteEvent") then listen(teleportRemote.OnClientEvent, function(kind: any) if kind == "Done" then salePositionChanged() end end) end
	if seedShop then listen(seedShop.OnClientEvent, function() wake() end) end
	if eggRemote then listen(eggRemote.OnClientEvent, function(kind: any, map: any)
		if kind == "Stock" and type(map) == "table" then eggStock = table.clone(map) wake() end
	end) end
	local balance = moneyValue()
	if balance then listen(balance:GetPropertyChangedSignal("Value"), function() wake() end) end
	bindInventory("Backpack", player:FindFirstChildOfClass("Backpack"))
	bindInventory("Character", player.Character)
	bindInventory("Pets", player:FindFirstChild("PetsOwned"))
	Window:OnClose(function()
		for id in pairs(enabled) do enabled[id] = false end
		cancelWorker()
		clearTravel()
		pending = nil
	end)
	handles.Actions = actions

	Window:SetReady("Garden dashboard and Shops ready")
	return {Shops = handles}
end
