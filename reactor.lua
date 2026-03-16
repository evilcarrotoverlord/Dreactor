_G.OS_VERSION = "0.3"
local VERSION_URL = "https://api.github.com/repos/evilcarrotoverlord/Dreactor/releases"
local lastState = ""
local lastStatus = ""
local currentScale = {}
local runningTotalRF = 0
local needsFullRedraw = true
local lastHourLog = os.clock()
local lastForceRecoveryState = false
local lastNBTReductionState = false
local criticalLogged = false
local fuelBuffer = {}
local tempBuffer = {}
local forceRecovery = false
local lastNBTReductionLog = 0
local lastForceRecoveryLog = 0
local LOG_COOLDOWN = 10
local Shuttingdown = false
local lastTemp = 0
local isFineTuning = false
local adjustmentTick = 0
local SLOW_RATE = 10
local targetNBT = 2.000
local function findPeripherals(name)
	local found = {}
	local names = peripheral.getNames()
	for _, v in ipairs(names) do
		if peripheral.getType(v):find(name) then
			local p = peripheral.wrap(v)
			p.id = v
			table.insert(found, p)
		end
	end
	return found
end
local function saveConfig(mode, totalRF, targetNBT)
	local f = fs.open("React.conf", "w")
	f.writeLine("mode=" .. (mode or "Manual"))
	f.writeLine("totalRF=" .. math.floor(totalRF or 0))
	f.writeLine("targetNBT=" .. (targetNBT or 2.000))
	f.close()
end
local function loadConfig()
	if not fs.exists("React.conf") then return {mode = "Manual", totalRF = 0, targetNBT = 2.000} end
	local f = fs.open("React.conf", "r")
	local cfg = {mode = "Manual", totalRF = 0, targetNBT = 2.000}
	local line = f.readLine()
	while line do
		local k, v = line:match("([^=]+)=([^=]+)")
		if k == "mode" then cfg.mode = v end
		if k == "totalRF" then cfg.totalRF = tonumber(v) or 0 end
		if k == "targetNBT" then cfg.targetNBT = tonumber(v) or 2.000 end
		line = f.readLine()
	end
	f.close()
	return cfg
end
local function setMonitorScale(target)
	if target == term then return end
	local id = peripheral.getName(target)
	if not currentScale[id] or needsFullRedraw then
		target.setTextScale(1)
		local w, h = target.getSize()
		local desired = (w < 31 or h < 21) and 0.5 or 1
		target.setTextScale(desired)
		currentScale[id] = desired
	end
end
local function fetchReleases()
	local list = {}
	local response = http.get(VERSION_URL)
	if response then
		local data = textutils.unserialiseJSON(response.readAll())
		response.close()
		if data then
			for i, rel in ipairs(data) do
				local downloadUrl = nil
				for _, asset in ipairs(rel.assets or {}) do
					if asset.name == "installer.lua" then
						downloadUrl = asset.browser_download_url
						break
					end
				end
				table.insert(list, {
					tag = rel.tag_name,
					url = downloadUrl,
					isLatest = (i == 1),
					isCurrent = (rel.tag_name == _G.OS_VERSION)
				})
			end
		end
	end
	return list
end
local function drawSelectionMenu(target, releases, selectedIdx, scrollOffset)
	local w, h = target.getSize()
	target.setBackgroundColor(colors.gray)
	target.clear()
	target.setCursorPos(1, 1)
	target.setBackgroundColor(colors.purple)
	target.setTextColor(colors.white)
	target.clearLine()
	local title = " UPDATE MANAGER "
	target.setCursorPos(math.floor(w/2 - #title/2), 1)
	target.write(title)
	local winX, winY, winW, winH = 3, 3, w - 4, h - 5
	target.setBackgroundColor(colors.lightGray)
	for i = 0, winH - 1 do
		target.setCursorPos(winX, winY + i)
		target.write(string.rep(" ", winW))
	end
	local visibleRows = math.floor((winH - 2) / 1)
	for i = 1, visibleRows do
		local idx = i + scrollOffset
		if releases[idx] then
			local rel = releases[idx]
			target.setCursorPos(winX + 1, winY + i)
			if idx == selectedIdx then
				target.setBackgroundColor(colors.blue)
				target.setTextColor(colors.white)
			else
				target.setBackgroundColor(colors.gray)
				target.setTextColor(colors.lightGray)
			end
			local label = string.format(" %-12s %s", rel.tag, (rel.isLatest and "[NEW]" or (rel.isCurrent and "[LIVE]" or "")))
			target.write(label .. string.rep(" ", winW - #label - 2))
		end
	end
	target.setBackgroundColor(colors.green)
	target.setTextColor(colors.black)
	target.setCursorPos(winX, winY + winH)
	target.write(" [ INSTALL ] ")	
	target.setBackgroundColor(colors.red)
	target.setTextColor(colors.white)
	target.setCursorPos(winX + winW - 12, winY + winH)
	target.write(" [ CANCEL ] ")
end
local function openUpdateMenu(target)
	target.setBackgroundColor(colors.black)
	target.setTextColor(colors.white)
	target.clear()
	local loadMsg = "Connecting to GitHub..."
	local w, h = target.getSize()
	target.setCursorPos(w/2 - #loadMsg/2, h/2)
	target.write(loadMsg)
	local releases = fetchReleases()
	if #releases == 0 then 
		needsFullRedraw = true
		return 
	end
	local selectedIdx = 1
	local scrollOffset = 0
	local winX, winY, winW, winH = 3, 3, w - 4, h - 5
	local visibleRows = math.floor((winH - 2) / 1)
	while true do
		drawSelectionMenu(target, releases, selectedIdx, scrollOffset)
		local event, p1, p2, p3 = os.pullEvent()
		if event == "key" then
			if p1 == keys.up and selectedIdx > 1 then
				selectedIdx = selectedIdx - 1
			elseif p1 == keys.down and selectedIdx < #releases then
				selectedIdx = selectedIdx + 1
			elseif p1 == keys.enter then
				break
			elseif p1 == keys.q then
				needsFullRedraw = true
				return
			end
		elseif event == "mouse_click" or event == "monitor_touch" then
			local mx, my = p2, p3
			if my == winY + winH then
				if mx >= winX and mx <= winX + 12 then break end
				if mx >= winX + winW - 11 and mx <= winX + winW then 
					needsFullRedraw = true
					return 
				end 
			end
			if my > winY and my < winY + winH then
				local clickedIdx = (my - winY) + scrollOffset
				if releases[clickedIdx] then selectedIdx = clickedIdx end
			end
		end
		if selectedIdx <= scrollOffset then scrollOffset = selectedIdx - 1 end
		if selectedIdx > scrollOffset + visibleRows then scrollOffset = selectedIdx - visibleRows end
	end
	local targetRel = releases[selectedIdx]
	if targetRel and targetRel.url then
		local res = http.get(targetRel.url)
		if res then
			local code = res.readAll()
			res.close()
			term.setBackgroundColor(colors.black)
			term.clear()
			term.setCursorPos(1,1)
			print("Installing " .. targetRel.tag .. "...")
			local func = load(code, "installer", "t", _ENV)
			if func then 
				pcall(func) 
				os.reboot() 
			end
		end
	end
	needsFullRedraw = true
end
local function formatTime(seconds)
	if seconds <= 0 or seconds > 10^9 then return "Infinite" end
	local days = math.floor(seconds / 86400)
	local hours = math.floor((seconds % 86400) / 3600)
	local mins = math.floor((seconds % 3600) / 60)
	return string.format("%dd:%dh:%dm", days, hours, mins)
end
local function formatRF(val)
	local units = {"rf", "Krf", "Mrf", "Grf", "Trf", "Erf"}
	local unit = 1
	local absVal = math.abs(val)
	while absVal >= 1000 and unit < #units do
		absVal = absVal / 1000
		unit = unit + 1
	end
	local str = string.format("%.2f", (val < 0 and -absVal or absVal))
	str = str:gsub("%.?0+$", "")
	return str .. units[unit]
end
local function getTempColor(temp)
	if temp < 2000 then return colors.lightBlue
	elseif temp < 4500 then return colors.yellow
	elseif temp < 7500 then return colors.green
	elseif temp < 8500 then return colors.orange
	else return colors.red end
end
local function smartFormat(val, precision)
	local str = string.format("%." .. precision .. "f", val)
	str = str:gsub("%.?0+$", "")
	return str .. "%"
end
local function drawSetupUI(target, reactors, gates, inID, outID)
	if not target then return end
	setMonitorScale(target)
	target.setBackgroundColor(colors.gray)
	target.clear()
	target.setCursorPos(1, 1)
	target.setBackgroundColor(colors.purple)
	target.setTextColor(colors.white)
	target.clearLine()
	target.write(" [ REACTOR PREBOOT CHECK ] ")
	target.setBackgroundColor(colors.gray)
	target.setCursorPos(1, 3)
	target.setTextColor(colors.orange)
	target.write(" CORE:  ")
	target.setTextColor(#reactors > 0 and colors.green or colors.red)
	target.write(#reactors > 0 and "ONLINE" or "MISSING")
	target.setCursorPos(1, 5)
	target.setTextColor(colors.purple)
	target.write("--- GATE CONFIGURATION ---")	
	target.setCursorPos(1, 6)
	target.setTextColor(colors.white)
	target.write("Set 'Redstone Signal High' to 1 on INPUT")	
	for i, g in ipairs(gates) do
		local val = g.getSignalHighFlow()
		target.setCursorPos(1, 7 + i)
		target.setTextColor(colors.orange)
		target.write(string.format("[%d] %s ", i, g.id))
		if val == 1 then
			target.setTextColor(colors.purple)
			target.write("-> [ INPUT ]")
		else
			target.setTextColor(colors.gray)
			target.write("-> [ OUTPUT ]")
		end
	end
end
local function logReactorEvent(info, targetNBT, disclaimer)
	local logs = {}
	if fs.exists("reactor.log") then
		local f = fs.open("reactor.log", "r")
		local line = f.readLine()
		while line do
			table.insert(logs, line)
			line = f.readLine()
		end
		f.close()
	end
	local fPct = 100 - ((info.fuelConversion / info.maxFuelConversion) * 100)
	local sPct = (info.fieldStrength / info.maxFieldStrength) * 100
	local ePct = (info.energySaturation / info.maxEnergySaturation) * 100
	local timestamp = os.date("%Y-%m-%d %H:%M:%S")
	local logEntry = string.format("[%s] %sGen: %s | NBT: %.3f | Temp: %dC | Shld: %.1f%% | Sat: %.1f%% | Fuel: %.2f%%",
		timestamp,
		disclaimer and (disclaimer .. " | ") or "",
		formatRF(info.generationRate),
		info.fuelConversionRate / 1000,
		math.floor(info.temperature),
		sPct,
		ePct,
		fPct
	)
	table.insert(logs, logEntry)
	while #logs > 128 do table.remove(logs, 1) end

	local f = fs.open("reactor.log", "w")
	for _, l in ipairs(logs) do f.writeLine(l) end
	f.close()
end
local function drawHorizontalBar(target, x, y, width, percent, color)
	local fillWidth = math.floor(width * (percent / 100))
	target.setCursorPos(x, y)
	for i = 0, width - 1 do
		target.setBackgroundColor(i < fillWidth and color or colors.lightGray)
		target.write(" ")
	end
	target.setBackgroundColor(colors.gray)
end
local function adjustFuelRate(info, outGate, targetFuelRate)
	local currentRate = info.fuelConversionRate or 0
	local ePct = (info.energySaturation / info.maxEnergySaturation) * 100
	local effectiveTarget = targetFuelRate
	if ePct < 20 then
		effectiveTarget = targetFuelRate * 0.7
	end
	local rateDifference = (effectiveTarget * 1000) - currentRate
	local currentOutput = outGate.getSignalLowFlow()
	if math.abs(rateDifference) >= 0.2 then
		local absDiff = math.abs(rateDifference)
		local adjustment = 0
		if absDiff <= 0.5 then adjustment = 50
		elseif absDiff <= 1 then adjustment = 200
		elseif absDiff <= 2 then adjustment = 500
		elseif absDiff <= 5 then adjustment = 1000
		elseif absDiff <= 10 then adjustment = 2500
		elseif absDiff <= 20 then adjustment = 10000
		else adjustment = 20000 end
		if rateDifference < 0 then
			adjustment = -adjustment
		end
		local newOutput = math.max(0, currentOutput + adjustment)
		outGate.setSignalLowFlow(newOutput)
	end
end
local function adjustFuelForTempOnly(ri, currentTargetFuelRate)
	local fuelPercent = 100 - (math.ceil(ri.fuelConversion / ri.maxFuelConversion * 10000) * 0.01)
	local currentTemp = ri.temperature
	local targetTemp = 8000
	if fuelPercent > 99 then targetTemp = 5000
	elseif fuelPercent > 98 then targetTemp = 5500
	elseif fuelPercent > 97 then targetTemp = 6000
	elseif fuelPercent > 96 then targetTemp = 6500
	elseif fuelPercent > 95 then targetTemp = 7000
	elseif fuelPercent > 94 then targetTemp = 7500
	elseif fuelPercent > 93 then targetTemp = 7700
	else targetTemp = 8000 end
	if targetTemp == 8000 then
		adjustmentTick = adjustmentTick + 1
		if adjustmentTick % SLOW_RATE ~= 0 then
			return currentTargetFuelRate
		end
	else
		adjustmentTick = 0
	end
	if (lastTemp < targetTemp and currentTemp >= targetTemp) or (lastTemp > targetTemp and currentTemp <= targetTemp) then
		isFineTuning = true
	end
	lastTemp = currentTemp
	if math.abs(targetTemp - currentTemp) < 0.1 then
		return currentTargetFuelRate
	end
	local step = isFineTuning and 0.001 or 0.01
	if currentTemp < targetTemp then
		currentTargetFuelRate = currentTargetFuelRate + step
	elseif currentTemp > targetTemp then
		currentTargetFuelRate = math.max(0.1, currentTargetFuelRate - step)
	end
	return currentTargetFuelRate
end
local function drawButton(target, x, y, width, height, text, bgColor, textColor)
	target.setTextColor(textColor)
	target.setBackgroundColor(bgColor)
	local label = " " .. text .. " "
	local padding = math.floor((width - #label) / 2)
	local fullStr = string.rep(" ", padding) .. label .. string.rep(" ", width - #label - padding)
	for i = 0, height - 1 do
		target.setCursorPos(x, y + i)
		target.write(i == height - 1 and fullStr or string.rep(" ", width))
	end
end
function balanceReactorInput(reactor, inputGate, targetPercent)
	local ri = reactor.getReactorInfo()
	if not ri or not ri.fieldDrainRate or ri.fieldDrainRate ~= ri.fieldDrainRate then 
		return false 
	end
	if ri.status == "warming_up" or ri.status == "cold" then
		return false
	end
	local currentField = (ri.fieldStrength / ri.maxFieldStrength) * 100
	local drain = ri.fieldDrainRate
	local baseInput = drain / (1 - (targetPercent / 100))
	local diff = targetPercent - currentField
	local gain = 5000
	local correction = diff * gain
	local finalInput = math.max(0, math.floor(baseInput + correction))
	if finalInput == finalInput and finalInput ~= math.huge then
		inputGate.setSignalLowFlow(finalInput)
		return finalInput
	end
	return false
end
local function drawMainUI(target, info, mode, inGate, outGate)
	if not target then return end
	setMonitorScale(target)
	local w, h = target.getSize()
	local halfH = math.floor(h / 2)
	if needsFullRedraw then
		target.setBackgroundColor(colors.gray)
		target.clear()
		needsFullRedraw = false
	end
	local statusLine = " CORE: " .. info.status:upper()
	local versionTag = "Dreactor " .. _G.OS_VERSION
	target.setCursorPos(1, 1)
	target.setBackgroundColor(colors.purple)
	target.setTextColor(colors.white)
	target.write(statusLine .. string.rep(" ", w - #statusLine))
	target.setCursorPos(math.floor(w/2 - #versionTag/2), 1)
	target.write(versionTag)
	local deg = string.char(176)
	local tCol = getTempColor(info.temperature)
	local tempText = "TEMP: " .. math.floor(info.temperature) .. deg .. "C "
	target.setCursorPos(w - #tempText + 1, 1)
	target.setTextColor(tCol)
	target.write(tempText)
	local startX, barW, startY = 2, w - 8, 2
	target.setTextColor(colors.white)	
	target.setCursorPos(startX, startY)
	target.setBackgroundColor(colors.gray)
	target.write("SHIELD STRENGTH")
	local sPct = (info.fieldStrength / info.maxFieldStrength) * 100
	drawHorizontalBar(target, startX, startY + 1, barW, sPct, sPct < 20 and colors.red or colors.blue)
	local sVal = smartFormat(sPct, 1)
	target.setCursorPos(w - #sVal, startY + 1)
	target.write(sVal)
	target.setCursorPos(startX, startY + 2)
	target.write("ENERGY SATURATION")
	local ePct = (info.energySaturation / info.maxEnergySaturation) * 100
	local eCol = ePct < 20 and colors.red or (ePct < 80 and colors.green or colors.white)
	drawHorizontalBar(target, startX, startY + 3, barW, ePct, eCol)
	local eVal = smartFormat(ePct, 1)
	target.setCursorPos(w - #eVal, startY + 3)
	target.write(eVal)
	target.setCursorPos(startX, startY + 4)
	target.write("FUEL CONVERSION")
	local fPct = 100 - ((info.fuelConversion / info.maxFuelConversion) * 100)
	local fCol = fPct < 20 and colors.red or (fPct < 50 and colors.orange or colors.green)
	drawHorizontalBar(target, startX, startY + 5, barW, fPct, fCol)
	local fVal = smartFormat(fPct, 2)
	target.setCursorPos(w - #fVal, startY + 5)
	target.write(fVal)
	target.setBackgroundColor(colors.black)
	target.setCursorPos(1, halfH)
	target.write(string.rep(" ", w))
	local divX = 13 
	for i = halfH, h do
		target.setCursorPos(divX, i)
		target.write(" ")
	end
	local btnW = 10
	local btnH = 2
	local modeY = halfH + 3
	local chargeY = modeY + btnH + 1
	local shutdownY = chargeY + btnH + 1
	local mCol, mTextCol = colors.lightGray, colors.gray
	if mode == "Manual" then
		local adjY = modeY - 1
		local btnS = 2
		target.setBackgroundColor(colors.gray)
		target.setTextColor(colors.gray)		
		target.setCursorPos(2, adjY)
		target.setBackgroundColor(colors.red)
		target.write("<< ")		
		target.setCursorPos(5, adjY)
		target.setBackgroundColor(colors.orange)
		target.write("< ")		
		target.setCursorPos(7, adjY)
		target.setBackgroundColor(colors.green)
		target.write(" >")		
		target.setCursorPos(9, adjY)
		target.setBackgroundColor(colors.lime)
		target.write(" >>")
	elseif mode == "Auto8k" then
		local adjY = modeY - 1
		target.setBackgroundColor(colors.gray)
		target.write("         ")
	elseif mode == "AutoNBT" then
		local adjY = modeY - 1
		local btnS = 2
		target.setBackgroundColor(colors.gray)
		target.setTextColor(colors.gray)		
		target.setCursorPos(2, adjY)
		target.setBackgroundColor(colors.red)
		target.write("<< ")		
		target.setCursorPos(5, adjY)
		target.setBackgroundColor(colors.orange)
		target.write("< ")		
		target.setCursorPos(7, adjY)
		target.setBackgroundColor(colors.green)
		target.write(" >")		
		target.setCursorPos(9, adjY)
		target.setBackgroundColor(colors.lime)
		target.write(" >>")
	end
	if info.status == "running" then
		mTextCol = colors.black
		if mode == "Manual" then mCol = colors.yellow
		elseif mode == "AutoNBT" then mCol = colors.purple
		elseif mode == "Auto8k" then mCol = colors.orange end
	end
	drawButton(target, 2, modeY, btnW, btnH, mode:upper(), mCol, mTextCol)
	if info.status == "cold" then
		drawButton(target, 2, chargeY, btnW, btnH, "CHARGE", colors.green, colors.black)
	else
		local cCol = (info.status:find("warming") or info.status:find("online")) and colors.lightGray or colors.lightGray
		local cTxt = (info.status:find("warming") or info.status:find("online")) and colors.gray or colors.black
		drawButton(target, 2, chargeY, btnW, btnH, info.status == "warming_up" and "CHARGING" or "ONLINE", cCol, cTxt)
	end
	local sCol = info.status == "cold" and colors.lightGray or colors.red
	local sTxt = info.status == "cold" and colors.gray or colors.black
	drawButton(target, 2, shutdownY, btnW, btnH, "SHUTDOWN", sCol, sTxt)
	target.setBackgroundColor(colors.gray)
	local infoX = divX + 1
	local infoY = halfH + 1
	target.setTextColor(colors.lightGray)
	target.setCursorPos(infoX, infoY)
	target.write("GENERATION:")
	target.setTextColor(colors.green)
	local netGen = info.generationRate - (inGate and inGate.getSignalLowFlow() or 0)
	target.write(formatRF(netGen) .. "/t      ")
	target.setCursorPos(infoX, infoY + 1)
	target.setTextColor(colors.lightGray)
	target.write("TOTAL:")
	target.setTextColor(colors.orange)
	target.write(formatRF(runningTotalRF))
	target.write("     ")
	target.setCursorPos(infoX, infoY + 2)
	target.setTextColor(colors.lightGray)
	target.write("I/O ")
	target.setTextColor(colors.green)
	target.write("IN:" .. formatRF(inGate and inGate.getSignalLowFlow() or 0))
	target.setTextColor(colors.red)
	target.write(" OUT:" .. formatRF(outGate and outGate.getSignalLowFlow() or 0))
	target.write("     ")
	local currentNBT = info.fuelConversionRate / 1000
	local nbtStr = string.format("%.3f", currentNBT)
	local currentNBT = info.fuelConversionRate / 1000
	local ePct = (info.energySaturation / info.maxEnergySaturation) * 100	
	target.setCursorPos(infoX, infoY + 3)
	target.setTextColor(colors.lightGray)
	target.write("TARGET:  ")
	local displayNBT = targetNBT
	if ePct < 20 then
		target.setTextColor(colors.red)
		displayNBT = targetNBT * 0.7
		target.write(string.format("%.3fnb/t ", displayNBT))
	else
		target.setTextColor(colors.purple)
		target.write(string.format("%.3fnb/t ", targetNBT))
	end
	if mode == "Auto8k" then
		local fuelPercent = 100 - (math.ceil(info.fuelConversion / info.maxFuelConversion * 10000) * 0.01)
		local tTemp = 8000
		if fuelPercent > 99 then tTemp = 5000
		elseif fuelPercent > 98 then tTemp = 5500
		elseif fuelPercent > 97 then tTemp = 6000
		elseif fuelPercent > 96 then tTemp = 6500
		elseif fuelPercent > 95 then tTemp = 7000
		elseif fuelPercent > 94 then tTemp = 7500
		elseif fuelPercent > 93 then tTemp = 7700 end
		target.setTextColor(getTempColor(tTemp))
		target.write(string.format("%d%sC", tTemp, deg))
	else
		target.write("       ")
	end
	target.setCursorPos(infoX, infoY + 4)
	target.setTextColor(colors.lightGray)
	target.write("CURRENT: ")
	target.setTextColor(colors.orange)	
	if mode == "Auto8k" then
		target.write(string.format("%.3fnb/t ", currentNBT))
		target.setTextColor(getTempColor(info.temperature))
		target.write(string.format("%d%sC", math.floor(info.temperature), deg))
	else
		target.write(string.format("%.3fnb/t", currentNBT))
	end
	local timeStr = "Infinite"
	local timeLabel = "EST. TIME: "
	local timeCol = colors.yellow
	if info.status == "running" or info.status == "online" then
		local avgDrainNBT = 0
		if #fuelBuffer > 0 then
			local sum = 0
			for _, v in ipairs(fuelBuffer) do sum = sum + v end
			avgDrainNBT = sum / #fuelBuffer
		end
		if avgDrainNBT > 0 then
			local remainingFuel = info.maxFuelConversion - info.fuelConversion
			local nbtPerSecond = (avgDrainNBT / 1000000) * 20
			timeStr = formatTime(remainingFuel / nbtPerSecond)
		end
	elseif info.temperature > 25 then
		timeLabel = "COOL DOWN: "
		timeCol = colors.lightBlue		
		local avgDrop = 0
		if #tempBuffer >= 10 then
			avgDrop = tempBuffer[1] - tempBuffer[#tempBuffer]
		end
		if avgDrop > 0 then
			local degreesToCool = info.temperature - 20
			local secondsToCold = degreesToCool / (avgDrop / #tempBuffer)
			timeStr = formatTime(secondsToCold)
		else
			timeStr = "Cooling..."
		end
	end
	target.setCursorPos(infoX, infoY + 5)
	target.setTextColor(colors.lightGray)
	target.write(timeLabel)
	target.setTextColor(timeCol)
	target.write(timeStr .. "           ")
end
local function handleInteraction(x, y, info, reactor, inGate, outGate, target, cfg)
	if not target then return end
	local w, h = target.getSize()
	if y == 1 then
		local versionTag = "Dreactor v" .. _G.OS_VERSION
		local startX = math.floor(w/2 - #versionTag/2)
		if x >= startX and x <= startX + #versionTag then
			openUpdateMenu(target)
			return
		end
	end
	local halfH = math.floor(h / 2)
	local btnW = 10
	local btnH = 2	
	local modeY = halfH + 3
	local chargeY = modeY + btnH + 1
	local shutdownY = chargeY + btnH + 1
	local adjY = modeY - 1
	if y == adjY then
		local change = 0
		if x >= 2 and x <= 4 then change = -1.0
		elseif x >= 5 and x <= 6 then change = -0.1
		elseif x >= 7 and x <= 8 then change = 0.1
		elseif x >= 9 and x <= 11 then change = 1.0 end
		if change ~= 0 then
			if cfg.mode == "Manual" then
				if outGate then
					local currentOut = outGate.getSignalLowFlow()
					local multiplier = (math.abs(change) == 1 and 1000000 or 100000)
					local newVal = math.max(0, currentOut + (change > 0 and multiplier or -multiplier))
					outGate.setSignalLowFlow(newVal)
				end
			elseif cfg.mode == "AutoNBT" then
				targetNBT = math.max(0.1, targetNBT + change)
				saveConfig(cfg.mode, runningTotalRF, targetNBT)
			end
		end
	end
	if x >= 2 and x <= 2 + btnW then
		if y >= modeY and y < (modeY + btnH) then
			local modes = {"Manual", "AutoNBT", "Auto8k"}
			local nextM = "Manual"
			for i, m in ipairs(modes) do
				if m == cfg.mode then nextM = modes[i % 3 + 1] break end
			end
			cfg.mode = nextM
			saveConfig(cfg.mode, runningTotalRF, targetNBT)
		elseif y >= chargeY and y < (chargeY + btnH) then
			if info.status == "cold" then
				local Shuttingdown = false
				inGate.setSignalLowFlow(900000)
				outGate.setSignalLowFlow(0)
				reactor.chargeReactor()
			elseif info.status == "warming_up" and info.temperature >= 2000 then
				inGate.setSignalLowFlow(900000)
				outGate.setSignalLowFlow(0)
				reactor.activateReactor()
			end
		elseif y >= shutdownY and y < (shutdownY + btnH) then
			if info.status ~= "cold" then
				inGate.setSignalLowFlow(900000)
				outGate.setSignalLowFlow(0)
				Shuttingdown = true
				reactor.stopReactor()
			end
		end
	end
end
local lastSave = os.clock()
local function main()
	local lastTime = os.epoch("utc")
	local firstRun = true
	local cfg = loadConfig() or {mode = "AutoNBT", totalRF = 0}
	currentScale = {}
	targetNBT = cfg.targetNBT or 2.000
	term.setBackgroundColor(colors.gray)
	term.clear()
	
	local monitor = findPeripherals("monitor")[1]
	if monitor then
		monitor.setBackgroundColor(colors.gray)
		monitor.clear()
	end
	needsFullRedraw = true 
	while true do
		local reactors = findPeripherals("draconic_reactor")
		local gates = findPeripherals("flow_gate")
		local monitor = findPeripherals("monitor")[1]
		if firstRun then
			runningTotalRF = cfg.totalRF or 0
			firstRun = false
		end
		local inGate, outGate = nil, nil
		for _, g in ipairs(gates) do
			if g.getSignalHighFlow() == 1 then 
				inGate = g 
			else 
				outGate = g 
			end
		end
		local setupValid = (#reactors > 0 and inGate ~= nil and outGate ~= nil)
		if setupValid then
			local reactor = reactors[1]
			balanceReactorInput(reactor, inGate, 50)
			local info = reactor.getReactorInfo()
			local sPct = (info.fieldStrength / info.maxFieldStrength) * 100
			local ePct = (info.energySaturation / info.maxEnergySaturation) * 100
			if info.temperature >= 10000 and info.status ~= "cold" then
				reactor.stopReactor()
				inGate.setSignalLowFlow(4000000)
				outGate.setSignalLowFlow(0)
				Shuttingdown = true
			end
			if Shuttingdown then
				if info.temperature <= 200 then
					inGate.setSignalLowFlow(100)
				elseif info.temperature > 200 and info.temperature < 8000 then
					inGate.setSignalLowFlow(900000)
				end
				if info.status == "cold" then
					Shuttingdown = false
				end
			end
			if os.clock() - lastHourLog >= 3600 then
				logReactorEvent(info, targetNBT)
				lastHourLog = os.clock()
			end
			if forceRecovery then
				if currentTime - lastForceRecoveryLog >= LOG_COOLDOWN then
					logReactorEvent(info, targetNBT, "EMERGENCY: FORCE RECOVERY ACTIVE")
					lastForceRecoveryLog = currentTime
				end
			end
			if ePct < 20 then
				if currentTime - lastNBTReductionLog >= LOG_COOLDOWN then
					logReactorEvent(info, targetNBT, "SAFETY: 30% NBT REDUCTION ACTIVE")
					lastNBTReductionLog = currentTime
				end
			end
			lastNBTReductionState = nbtReductionActive
			if info.temperature >= 10000 and not Shuttingdown then
				logReactorEvent(info, targetNBT, "CRITICAL: OVER-TEMP SHUTDOWN")
			end
			if info.status == "beyond_hope" and not criticalLogged then
				logReactorEvent(info, targetNBT, "TERMINAL: REACTOR GOING CRITICAL")
				criticalLogged = true
			elseif info.status ~= "beyond_hope" then
				criticalLogged = false
			end
			if sPct <= 10 or ePct <= 10 then
				forceRecovery = true
			elseif sPct >= 30 and ePct >= 30 then
				forceRecovery = false
			end
			if forceRecovery then
				outGate.setSignalLowFlow(0)
			elseif cfg.mode == "Auto8k" then
				targetNBT = adjustFuelForTempOnly(info, targetNBT)
				adjustFuelRate(info, outGate, targetNBT)
			elseif cfg.mode == "AutoNBT" then
				adjustFuelRate(info, outGate, targetNBT)
			end
			local currentTime = os.epoch("utc")
			local elapsedSeconds = (currentTime - lastTime) / 1000
			if info.status == "warming_up" and info.temperature >= 2000 then
				reactor.activateReactor()
			end
			lastTime = currentTime
			table.insert(fuelBuffer, info.fuelConversionRate)
			if #fuelBuffer > 60 then table.remove(fuelBuffer, 1) end
			table.insert(tempBuffer, info.temperature)
			if #tempBuffer > 60 then table.remove(tempBuffer, 1) end
			if info.status == "running" or info.status == "online" then
				local ticksPassed = elapsedSeconds * 20
				runningTotalRF = runningTotalRF + (info.generationRate * ticksPassed)
			elseif (100 - ((info.fuelConversion / info.maxFuelConversion) * 100)) >= 99 then
				runningTotalRF = 0
			end
			if os.clock() - lastSave >= 60 then
				saveConfig(cfg.mode, runningTotalRF, targetNBT)
				lastSave = os.clock()
			end
			local currentState = info.status .. math.floor(info.temperature) .. math.floor(runningTotalRF)
			if currentState ~= lastState then
				lastState = currentState
				drawMainUI(term, info, cfg.mode, inGate, outGate)
				if monitor then drawMainUI(monitor, info, cfg.mode, inGate, outGate) end
			end
			local timer = os.startTimer(1)
			while true do
				local ev = {os.pullEvent()}
				if ev[1] == "timer" and ev[2] == timer then break end
				if ev[1] == "mouse_click" or ev[1] == "monitor_touch" then
					local targ = (ev[1] == "mouse_click") and term or monitor
					handleInteraction(ev[3], ev[4], info, reactor, inGate, outGate, targ, cfg)
					saveConfig(cfg.mode, runningTotalRF, targetNBT)
					lastState = "" 
					break
				end
			end
		else
			drawSetupUI(term, reactors, gates)
			if monitor then drawSetupUI(monitor, reactors, gates) end
			sleep(1)
		end
	end
end

main()
