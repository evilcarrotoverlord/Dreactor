_G.OS_VERSION = "0.5"
local VERSION_URL = "https://api.github.com/repos/evilcarrotoverlord/Dreactor/releases"
local lastState = ""
local currentScale = {}
local runningTotalRF = 0
local needsFullRedraw = true
local lastHourLog = os.clock()
local fuelBuffer = {}
local tempBuffer = {}
local forceRecovery = false
local lastNBTReductionLog = 0
local lastForceRecoveryLog = 0
local LOG_COOLDOWN = 10
local Shuttingdown = false
local refueling = false
local lastTemp = 0
local lastShield = 100
local lastSaturation = 100
local isFineTuning = false
local adjustmentTick = 0
local SLOW_RATE = 10
local targetNBT = 2.000
local shieldTarget = 50
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
local function getFuelPercent(info)
	return 100 - (math.ceil(info.fuelConversion / info.maxFuelConversion * 10000) * 0.01)
end
local function getFuelTargetTemp(fuelPercent)
	--if fuelPercent > 99 then return 5000
	--elseif fuelPercent > 98 then return 5500
	--elseif fuelPercent > 97 then return 6000
	--elseif fuelPercent > 96 then return 6500
	--elseif fuelPercent > 95 then return 7000
	--elseif fuelPercent > 94 then return 7500
	--elseif fuelPercent > 93 then return 7700
	--else 
	return 8000 
	--end
end
local function getReactorSafety(info)
	local sPct = (info.fieldStrength / info.maxFieldStrength) * 100
	local ePct = (info.energySaturation / info.maxEnergySaturation) * 100
	return {
		shield = sPct,
		saturation = ePct,
		isCritical = (info.temperature >= 10000 or sPct <= 10 or ePct <= 10 or info.status == "beyond_hope"),
		isLowSat = (ePct < 16),
		isDangerSat = (ePct < 15)
	}
end
local function saveConfig(mode, totalRF, targetNBT, shieldTarget)
	local f = fs.open("React.conf", "w")
	if f then
		f.writeLine("mode=" .. (mode or "Manual"))
		f.writeLine("totalRF=" .. math.floor(totalRF or 0))
		f.writeLine("targetNBT=" .. (targetNBT or 2.000))
		f.writeLine("shieldTarget=" .. (shieldTarget or 50))
		f.close()
	end
end
local function loadConfig()
	if not fs.exists("React.conf") then return {mode = "Manual", totalRF = 0, targetNBT = 2.000, shieldTarget = 50} end
	local f = fs.open("React.conf", "r")
	local cfg = {mode = "Manual", totalRF = 0, targetNBT = 2.000, shieldTarget = 50}
	local line = f.readLine()
	while line do
		local k, v = line:match("([^=]+)=([^=]+)")
		if k == "mode" then cfg.mode = v end
		if k == "totalRF" then cfg.totalRF = tonumber(v) or 0 end
		if k == "targetNBT" then cfg.targetNBT = tonumber(v) or 2.000 end
		if k == "shieldTarget" then cfg.shieldTarget = tonumber(v) or 50 end
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
local function openUpdateMenu(target)
	local w, h = target.getSize()
	local winX, winY, winW, winH = 3, 3, w - 4, h - 5
	local visibleRows = winH - 1
	target.setBackgroundColor(colors.black)
	target.setTextColor(colors.white)
	target.clear()
	local loadMsg = "Connecting to GitHub..."
	target.setCursorPos(math.floor(w/2 - #loadMsg/2), math.floor(h/2))
	target.write(loadMsg)
	local releases = fetchReleases()
	if #releases == 0 then 
		needsFullRedraw = true
		return 
	end
	local selectedIdx = 1
	local scrollOffset = 0
	while true do
		target.setBackgroundColor(colors.black)
		target.clear()
		target.setCursorPos(1, 1)
		target.setBackgroundColor(colors.purple)
		target.setTextColor(colors.black)
		target.clearLine()
		local title = " UPDATE MANAGER Current version:" .. _G.OS_VERSION
		target.setCursorPos(math.floor(w/2 - #title/2), 1)
		target.write(title)
		target.setCursorPos(winX, winY)
		target.setBackgroundColor(colors.black)
		target.setTextColor(colors.purple)
		target.write(string.char(151) .. string.rep(string.char(131), winW - 2))
		target.setBackgroundColor(colors.purple)
		target.setTextColor(colors.black)
		target.write(string.char(148))
		for i = 1, winH - 1 do
			local rowY = winY + i
			target.setCursorPos(winX, rowY)
			target.setBackgroundColor(colors.black)
			target.setTextColor(colors.purple)
			target.write(string.char(149))
			local idx = i + scrollOffset
			if releases[idx] then
				local rel = releases[idx]
				local label = string.format("%s %s", rel.tag, (rel.isLatest and "[NEW]" or (rel.isCurrent and "[LIVE]" or "")))
				local innerW = winW - 4
				local padding = innerW - #label
				local leftPad = math.floor(padding / 2)
				local rightPad = padding - leftPad
				local centeredLabel = string.rep(" ", leftPad) .. label .. string.rep(" ", rightPad)
				target.setCursorPos(winX + 2, rowY)
				if idx == selectedIdx then
					target.setBackgroundColor(colors.purple)
					target.setTextColor(colors.black)
					target.write(centeredLabel)
				else
					target.setBackgroundColor(colors.black)
					target.setTextColor(colors.orange)
					target.write(centeredLabel)
				end
			end
			target.setCursorPos(winX + winW - 1, rowY)
			target.setBackgroundColor(colors.purple)
			target.setTextColor(colors.black)
			target.write(string.char(149))
		end
		local buttonY = winY + winH
		target.setBackgroundColor(colors.purple)
		target.setCursorPos(winX, buttonY)
		target.setTextColor(colors.lime)
		target.write(" [ INSTALL ] ")
		target.setBackgroundColor(colors.black)
		local gutterStart = winX + 13
		local gutterEnd = (winX + winW - 1) - 13
		if gutterEnd >= gutterStart then
			target.setCursorPos(gutterStart, buttonY)
			target.write(string.rep(" ", gutterEnd - gutterStart + 1))
		end
		target.setBackgroundColor(colors.purple)
		target.setCursorPos(winX + winW - 13, buttonY)
		target.setTextColor(colors.red)
		target.write(" [ CANCEL ]  ")
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
			if my == buttonY then
				if mx >= winX and mx <= winX + 12 then break end
				if mx >= winX + winW - 13 and mx <= winX + winW then 
					needsFullRedraw = true
					return 
				end 
			end
			if my > winY and my < buttonY then
				local clickedIdx = (my - winY) + scrollOffset
				if releases[clickedIdx] then selectedIdx = clickedIdx end
			end
		end
		if selectedIdx <= scrollOffset then scrollOffset = selectedIdx - 1 end
		if selectedIdx > scrollOffset + (visibleRows - 1) then scrollOffset = selectedIdx - (visibleRows - 1) end
	end
	local targetRel = releases[selectedIdx]
	if targetRel and targetRel.url then
		local res = http.get(targetRel.url)
		if res then
			local code = res.readAll()
			res.close()
			term.setBackgroundColor(colors.black)
			term.clear()
			term.setCursorPos(1, 1)
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
	local fmt = "%" .. (precision + 3) .. "." .. precision .. "f"
	local str = string.format(fmt, val)
	return str .. "%"
end
local function drawSetupUI(target, reactors, gates)
	if not target then return end
	setMonitorScale(target)
	local w, h = target.getSize()
	local hasReactor = #reactors > 0
	local hasInput, hasOutput = false, false
	for _, g in ipairs(gates) do
		if g.getSignalHighFlow() == 1 then hasInput = true else hasOutput = true end
	end
	if needsFullRedraw then
		target.setBackgroundColor(colors.black)
		target.clear()
	end
	local function drawStatus(y, isPresent)
		target.setCursorPos(1, y)
		target.setBackgroundColor(colors.black)
		if isPresent then
			target.setTextColor(colors.green)
			target.write("O")
		else
			target.setTextColor(colors.red)
			target.write("X")
		end
	end
	target.setCursorPos(1, 1)
	target.setBackgroundColor(colors.purple)
	target.setTextColor(colors.black)
	target.clearLine()
	local title = "Setup incomplete"
	target.setCursorPos(math.floor(w/2 - #title/2), 1)
	target.write(title)
	target.setTextColor(peripheral.find("monitor") and colors.yellow or colors.red)
	target.setCursorPos(1, 1)
	target.write("MONITOR")
	target.setBackgroundColor(colors.black)
	drawStatus(2, hasReactor)
	target.setTextColor(colors.orange)
	target.write("Draconic Reactor core")
	drawStatus(3, hasInput)
	target.setTextColor(colors.blue)
	target.write("Input flux gate")
	drawStatus(4, hasOutput)
	target.setTextColor(colors.red)
	target.write("Output flux gate")
	drawStatus(5, hasReactor)
	target.setTextColor(colors.lightBlue)
	target.write("Reactor Energy injector")
	drawStatus(6, hasReactor)
	target.setTextColor(colors.yellow)
	target.write("Reactor stabilizer")
	target.setCursorPos(1, 7)
	target.setTextColor(colors.purple)
	target.write(string.rep("\131", w))
	target.setCursorPos(1, 8)
	target.setTextColor(colors.black)
	if hasReactor == false then
		target.setTextColor(colors.red)
	end
	target.write("make sure the core has 4")
	target.setCursorPos(1, 9)
	target.write("stabilizers at least 3")
	target.setCursorPos(1, 10)
	target.write("block away from the core")
	target.setCursorPos(1, 12)
	target.write("and one injector that")
	target.setCursorPos(1, 13)
	target.write("is faced towards it")
	target.setTextColor(colors.black)
	if hasOutput == false then
		target.setTextColor(colors.red)
	end
	target.setCursorPos(1, 15)
	target.write("no fluxgates found")
	target.setCursorPos(1, 16)
	target.write("make sure the modem")
	target.setCursorPos(1, 17)
	target.write("is connected(red)")
	local rightX = w - 10
	target.setTextColor(colors.purple)
	for i = 8, h do
		target.setCursorPos(rightX - 1, i)
		target.write("\149")
	end
	target.setTextColor(colors.black)
	if hasInput == false then
		target.setTextColor(colors.red)
	end
	target.setCursorPos(rightX, 2)
	target.write("SET INPUT")
	target.setCursorPos(rightX, 3)
	target.write("FLUXGATE")
	target.setCursorPos(rightX, 4)
	target.write("SIGNAL HIGH")
	target.setCursorPos(rightX, 5)
	target.write("TO 1 RF/t")
	local isGray = (math.floor(os.clock()) % 2 == 0)
	local function getC(present, color)
		if present then return color end
		return isGray and colors.lightGray or color
	end
	local cCore = getC(hasReactor, colors.orange)
	local cStab = getC(hasReactor, colors.yellow)
	local cInj = getC(hasReactor, colors.lightBlue)
	local cFin = getC(hasInput, colors.blue)
	local cFout = getC(hasOutput, colors.red)
	target.setTextColor(cCore)
	target.setCursorPos(rightX + 4, 11)
	target.write("\143")
	target.setTextColor(cStab)
	target.setCursorPos(rightX + 8, 11)
	target.write("\143")
	target.setCursorPos(rightX, 11)
	target.write("\143")
	target.setCursorPos(rightX + 4, 8)
	target.write("\143")
	target.setCursorPos(rightX + 4, 14)
	target.write("\143")
	target.setTextColor(cFout)
	target.setCursorPos(rightX + 9, 11)
	target.write("\143")
	target.setCursorPos(rightX + 7, 12)
	target.write("OUT")
	target.setTextColor(cInj)
	target.setCursorPos(rightX + 4, 16)
	target.write("\143")
	target.setTextColor(cFin)
	target.setCursorPos(rightX + 2, 17)
	target.write("IN\143")
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
	local safety = getReactorSafety(info)
	local fPct = 100 - ((info.fuelConversion / info.maxFuelConversion) * 100)
	local timestamp = os.date("%Y-%m-%d %H:%M:%S")
	local logEntry = string.format("[%s] %sGen: %s | NBT: %.3f | Temp: %dC | Shld: %.1f%% | Sat: %.1f%% | Fuel: %.2f%%",
		timestamp,
		disclaimer and (disclaimer .. " | ") or "",
		formatRF(info.generationRate),
		info.fuelConversionRate / 1000,
		math.floor(info.temperature),
		safety.shield,
		safety.saturation,
		fPct
	)
	table.insert(logs, logEntry)
	while #logs > 128 do table.remove(logs, 1) end

	local f = fs.open("reactor.log", "w")
	for _, l in ipairs(logs) do f.writeLine(l) end
	f.close()
end
local function triggerEmergencyRedstone()
	local sides = rs.getSides()
	for _, side in ipairs(sides) do
		rs.setOutput(side, true)
	end
end
local function drawHorizontalBar(target, x, y, width, percent, color)
	percent = math.max(0, math.min(100, percent))
	local fillWidth = math.ceil((width * percent) / 100)
	target.setCursorPos(x, y)
	for i = 1, width do
		if i <= fillWidth then
			target.setTextColor(color)
		else
			target.setTextColor(colors.gray)
		end
		target.write("\143")
	end
end
local function adjustFuelRate(info, outGate, targetFuelRate)
	local currentRate = info.fuelConversionRate or 0
	local safety = getReactorSafety(info)
	local rateDifference = (targetFuelRate * 1000) - currentRate
	local currentOutput = outGate.getSignalLowFlow()
	if math.abs(rateDifference) >= 0.2 then
		local absDiff = math.abs(rateDifference)
		local adjustment = 0
		if absDiff <= 0.01 then adjustment = 5
		elseif absDiff <= 0.02 then adjustment = 10
		elseif absDiff <= 0.05 then adjustment = 25
		elseif absDiff <= 0.2 then adjustment = 100
		elseif absDiff <= 0.4 then adjustment = 200
		elseif absDiff <= 0.8 then adjustment = 400
		elseif absDiff <= 1.2 then adjustment = 800
		else adjustment = 20000 end
		if rateDifference > 0 then
			if safety.isLowSat then
				return 
			end
			local multiplier = (safety.saturation / 100) * 2
			adjustment = adjustment * multiplier
		else
			local multiplier = (100 - safety.saturation) / 100
			adjustment = -adjustment * multiplier
		end
		local newOutput = math.max(0, currentOutput + adjustment)
		outGate.setSignalLowFlow(newOutput)
	end
end
local function adjustFuelForTempOnly(ri, currentTargetFuelRate)
	if not ri or not ri.fuelConversionRate then
		return currentTargetFuelRate
	end
	local fuelPercent = getFuelPercent(ri)
	local currentTemp = ri.temperature
	local currentNBT = ri.fuelConversionRate / 1000
	local targetTemp = getFuelTargetTemp(fuelPercent)
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
	local newTarget = currentTargetFuelRate
	if currentTemp < targetTemp then
		newTarget = currentTargetFuelRate + step
	elseif currentTemp > targetTemp then
		newTarget = math.max(0.1, currentTargetFuelRate - step)
	end
	if newTarget > (currentNBT + 0.100) then
		newTarget = currentNBT + 0.100
	end
	return newTarget
end
local function drawButton(target, x, y, width, height, text, bgColor, textColor, trimColor)
	bgColor, textColor, trimColor = bgColor or colors.blue, textColor or colors.gray, trimColor or colors.gray
	local label = " " .. text .. " "
	local padding = math.floor((width - #label) / 2)
	local labelStr = string.rep(" ", padding) .. label .. string.rep(" ", width - #label - padding)
	for i = 0, height - 1 do
		target.setCursorPos(x, y + i)
		local isTop = (i == 0)
		local isTextRow = (i == height - 1)
		target.setBackgroundColor(bgColor)
		target.setTextColor(trimColor)
		target.write(isTop and (string.char(151) .. string.rep(string.char(131), width - 2)) or string.char(149))
		if not isTop then
			target.setTextColor(textColor)
			target.write(isTextRow and labelStr:sub(2, -2) or string.rep(" ", width - 2))
		end
		target.setBackgroundColor(trimColor)
		target.setTextColor(bgColor)
		target.write(isTop and string.char(148) or string.char(149))
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
	local safety = getReactorSafety(info)
	local currentNBT = info.fuelConversionRate / 1000
	if not target then return end
	setMonitorScale(target)
	local w, h = target.getSize()
	local halfH = math.floor(h / 2)
	if needsFullRedraw then
		target.setBackgroundColor(colors.black)
		target.clear()
	end
	target.setTextColor(colors.black)
	local statusLine = " CORE: " .. info.status:upper()
	target.setTextColor(colors.black)
	local versionTag = "reactor " .. _G.OS_VERSION
	target.setCursorPos(1, 1)
	target.setBackgroundColor(colors.purple)
	target.write(statusLine .. string.rep(" ", w - #statusLine))
	target.setCursorPos(math.floor(w/2 - #versionTag/2), 1)
	target.setTextColor(colors.orange)
	target.write("D")
	target.setTextColor(colors.black)
	target.write(versionTag)
	local deg = string.char(176)
	local tCol = getTempColor(info.temperature)
	local tempText = "TEMP: " .. math.floor(info.temperature) .. deg .. "C "
	target.setCursorPos(w - #tempText + 1, 1)
	target.write(tempText)
	local startX, barW, startY = 2, w - 8, 2
	target.setCursorPos(startX, startY)
	target.setBackgroundColor(colors.black)
	target.setTextColor(colors.lightGray)
	target.write("SHIELD STRENGTH (Target: " .. shieldTarget .. "%)")
	drawHorizontalBar(target, startX, startY + 1, barW, safety.shield, safety.shield < 20 and colors.red or colors.blue)
	local sVal = smartFormat(safety.shield, 1)
	target.setCursorPos(w - #sVal, startY + 1)
	target.setTextColor(colors.lightGray)
	target.write(sVal)
	target.setCursorPos(startX, startY + 2)
	target.setTextColor(colors.lightGray)
	target.write("ENERGY SATURATION")
	local eCol = safety.saturation < 20 and colors.red or (safety.saturation < 80 and colors.green or colors.white)
	drawHorizontalBar(target, startX, startY + 3, barW, safety.saturation, eCol)
	local eVal = smartFormat(safety.saturation, 1)
	target.setCursorPos(w - #eVal, startY + 3)
	target.setTextColor(colors.lightGray)
	target.write(eVal)
	target.setCursorPos(startX, startY + 4)
	target.setTextColor(colors.lightGray)
	target.write("FUEL CONVERSION")
	local fPct = 100 - ((info.fuelConversion / info.maxFuelConversion) * 100)
	local fCol = fPct < 20 and colors.red or (fPct < 50 and colors.orange or colors.green)
	drawHorizontalBar(target, startX, startY + 5, barW, fPct, fCol)
	local fVal = smartFormat(fPct, 2)
	target.setCursorPos(w - #fVal, startY + 5)
	target.setTextColor(colors.lightGray)
	target.write(fVal)
	local divX = 13
	target.setBackgroundColor(colors.black)
	target.setTextColor(colors.purple)
	for i = halfH + 1, h do
		target.setCursorPos(divX, i)
		target.write("\149")
	end
	local btnW = 10
	local btnH = 2
	local modeY = halfH + 3
	local chargeY = modeY + btnH + 1
	local shutdownY = chargeY + btnH + 1
	local adjY = modeY - 1
	local mCol, mTextCol, mTrimCol = colors.blue, colors.gray, colors.gray
	local displayText = mode:upper()
	if mode == "Manual" then
		mCol, mTextCol, mTrimCol = colors.black, colors.yellow, colors.yellow
		displayText = "MANUAL"
	elseif mode == "AutoNBT" then
		mCol, mTextCol, mTrimCol = colors.black, colors.orange, colors.orange
		displayText = "AUTO NBT"
	elseif mode == "Auto8k" then
		mCol, mTextCol, mTrimCol = colors.black, colors.purple, colors.purple
		displayText = "AUTO 8K"
	end
	if info.status == "running" then
		target.setCursorPos(2, adjY)
		target.setBackgroundColor(colors.black)
		target.write("          ")
		if mode ~= "Auto8k" then
			target.setBackgroundColor(mCol)
			target.setTextColor(mTrimCol)
			target.setCursorPos(2, adjY)
			target.write(string.char(149) .. "<<")
			target.setCursorPos(5, adjY)
			target.write(string.char(149) .. "<")
			target.setCursorPos(7, adjY)
			target.write(">")
			target.setBackgroundColor(mTrimCol)
			target.setTextColor(mCol)
			target.write(string.char(149))
			target.setCursorPos(9, adjY)
			target.setBackgroundColor(mCol)
			target.setTextColor(mTrimCol)
			target.write(">>")
			target.setBackgroundColor(mTrimCol)
			target.setTextColor(mCol)
			target.write(string.char(149))
		end
	end
	drawButton(target, 2, modeY, btnW, btnH, displayText, mCol, mTextCol, mTrimCol)
	if info.status == "cold" then
		drawButton(target, 2, chargeY, btnW, btnH, "CHARGE", colors.black, colors.green, colors.green)
	else
		local cTxt = (info.status:find("warming") or info.status:find("online")) and colors.gray or colors.green
		drawButton(target, 2, chargeY, btnW, btnH, info.status == "warming_up" and "CHARGING" or "ONLINE", colors.black, cTxt, colors.green)
	end
	local sTxt = info.status == "cold" and colors.gray or colors.red
	drawButton(target, 2, shutdownY, btnW, btnH, "SHUTDOWN", colors.black, sTxt, colors.red)
	target.setBackgroundColor(colors.black)
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
	target.write(formatRF(runningTotalRF) .. "      ")
	target.setCursorPos(infoX, infoY + 2)
	target.setTextColor(colors.lightGray)
	target.write("RATE: ")
	local curNBT = info.fuelConversionRate / 1000
	local eff = (curNBT > 0) and (info.generationRate / curNBT) or 0
	target.setTextColor(colors.yellow)
	target.write(formatRF(eff) .. "/nb")
	target.setCursorPos(infoX, infoY + 3)
	target.setTextColor(colors.lightGray)
	target.write("I/O ")
	target.setTextColor(colors.green)
	target.write("IN:" .. formatRF(inGate and inGate.getSignalLowFlow() or 0))
	target.setTextColor(colors.red)
	target.write(" OUT:" .. formatRF(outGate and outGate.getSignalLowFlow() or 0) .. "      ")
	target.setCursorPos(infoX, infoY + 4)
	target.setTextColor(colors.lightGray)
	target.write("TARGET:  ")
	local displayNBT = targetNBT
	if mode == "Manual" then
		target.setTextColor(colors.lightGray)
	else
		if safety.isDangerSat then
			target.setTextColor(colors.red)
			displayNBT = targetNBT * 0.7
		elseif safety.isLowSat then
			target.setTextColor(colors.orange)
		else
			target.setTextColor(colors.purple)
		end
	end
	target.write(string.format("%.3fnb/t ", displayNBT))
	local fuelPercent = getFuelPercent(info)
	local tTemp = getFuelTargetTemp(fuelPercent)
	target.setTextColor(getTempColor(tTemp))
	target.write(string.format("%d%sC", tTemp, deg))
	target.setCursorPos(infoX, infoY + 5)
	target.setTextColor(colors.lightGray)
	target.write("CURRENT: ")
	target.setTextColor(colors.orange)	
	target.write(string.format("%.3fnb/t ", currentNBT))
	target.setTextColor(getTempColor(info.temperature))
	target.write(string.format("%d%sC", math.floor(info.temperature), deg))
	local timeStr = "Infinite"
	local timeLabel = "5% Fuel ETA: "
	local timeCol = colors.yellow
	if info.status == "running" or info.status == "online" then
		local avgDrainNBT = 0
		if #fuelBuffer > 0 then
			local sum = 0
			for _, v in ipairs(fuelBuffer) do sum = sum + v end
			avgDrainNBT = sum / #fuelBuffer
		end
		if avgDrainNBT > 0 then
			local maxFuel = info.maxFuelConversion
			local currentConverted = info.fuelConversion
			local fuelRemainingPct = 100 - ((currentConverted / maxFuel) * 100)
			local fuelUnitsPerSecond = (avgDrainNBT / 1000000) * 20			
			local targetConvertedAmount = 0
			if fuelRemainingPct > 5 then
				targetConvertedAmount = maxFuel * 0.95
				timeLabel = "5% Fuel ETA: "
			else
				targetConvertedAmount = maxFuel
				timeLabel = "0% Fuel ETA: "
			end
			local fuelToBurn = targetConvertedAmount - currentConverted			
			if fuelToBurn > 0 then
				local secondsRemaining = fuelToBurn / fuelUnitsPerSecond
				timeStr = formatTime(secondsRemaining)
			else
				timeStr = "00:00:00"
			end
		end
	elseif info.temperature > 25 then
		timeLabel = "COOL DOWN: "
		timeCol = colors.lightBlue		
		local avgDropPerSecond = 0
		if #tempBuffer >= 20 then
			local totalDrop = tempBuffer[1] - tempBuffer[#tempBuffer]
			avgDropPerSecond = totalDrop / #tempBuffer 
		end
		if avgDropPerSecond > 0.01 then
			local degreesToCool = info.temperature - 25
			local secondsToCold = degreesToCool / avgDropPerSecond
			timeStr = formatTime(secondsToCold)
		else
			timeStr = "Stable / Idle"
		end
	end
	target.setCursorPos(infoX, infoY + 6)
	target.setTextColor(colors.lightGray)
	target.write(timeLabel)
	target.setTextColor(timeCol)
	target.write(timeStr .. "           ")
	target.setCursorPos(1, halfH)
	target.setBackgroundColor(colors.black)
	target.setTextColor(colors.purple)	
	target.write(string.rep("\140", w))
	target.setCursorPos(divX, halfH)
	target.write("\156")
	target.setBackgroundColor(colors.black)
	target.setTextColor(colors.white)
end
local function handleInteraction(x, y, info, reactor, inGate, outGate, target, cfg)
	if not target then return end
	local w, h = target.getSize()
	local startX, barW, startY = 2, w - 8, 2
	if y == startY + 1 and x >= startX and x <= (startX + barW) then
		local rawPercent = ((x - startX) / (barW - 1)) * 100
		local newTarget = math.floor((rawPercent / 5) + 0.5) * 5
		if newTarget < 5 then 
			shieldTarget = 5
		elseif newTarget > 95 then 
			shieldTarget = 95
		else shieldTarget = newTarget end
		saveConfig(cfg.mode, runningTotalRF, targetNBT, shieldTarget)
		return
	end
	if y == 1 then
		local versionTag = "Dreactor v" .. _G.OS_VERSION
		local startX = math.floor(w/2 - #versionTag/2)
		if x >= startX and x <= startX + #versionTag then
			openUpdateMenu(target)
			needsFullRedraw = true
			lastState = ""
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
				saveConfig(cfg.mode, runningTotalRF, targetNBT, shieldTarget)
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
			saveConfig(cfg.mode, runningTotalRF, targetNBT, shieldTarget)
		elseif y >= chargeY and y < (chargeY + btnH) then
			if info.status == "cold" then
				Shuttingdown = false
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
local function triggerMeltdownAlarm(reason, temp, shield)
	triggerEmergencyRedstone(true)
	term.setBackgroundColor(colors.red)
	term.setTextColor(colors.white)
	term.clear()
	term.setCursorPos(1, 2)
	print(" !!! EMERGENCY MELTDOWN DETECTED !!!")
	print(" Reason: " .. reason)
	print(" Last Temp: " .. math.floor(temp) .. "C")
	print(" Shield: " .. math.floor(shield) .. "%")
	print(" Redstone Signal: LOCKED ON")
	while true do 
		os.pullEvent() 
	end
end
local lastSave = os.clock()
local function main()
	local lastTime = os.epoch("utc")
	local firstRun = true
	local cfg = loadConfig() or {mode = "AutoNBT", totalRF = 0}
	currentScale = {}
	targetNBT = cfg.targetNBT or 2.000
	term.setBackgroundColor(colors.black)
	term.clear()
	local monitor = findPeripherals("monitor")[1]
	if monitor then
		monitor.setBackgroundColor(colors.black)
		monitor.clear()
	end
	needsFullRedraw = true 
	while true do
		local reactors = findPeripherals("draconic_reactor")
		local gates = findPeripherals("flow_gate")
		local monitor = findPeripherals("monitor")[1]
		local currentTime = os.clock()
		if firstRun then
			runningTotalRF = cfg.totalRF or 0
			shieldTarget = cfg.shieldTarget or 50
			firstRun = false
		end
		local inGate, outGate = nil, nil
		for _, g in ipairs(gates) do
			if g.getSignalHighFlow() == 1 then inGate = g else outGate = g end
		end
		
		local setupValid = (#reactors > 0 and inGate ~= nil and outGate ~= nil)
		if setupValid then
			if not lastSetupState then
				needsFullRedraw = true
				lastSetupState = true
			end
			local reactor = reactors[1]
			balanceReactorInput(reactor, inGate, shieldTarget)
			local info = reactor.getReactorInfo()
			if not info then
				info = {
					status = "offline",
					temperature = lastTemp or 20,
					fieldStrength = 0,
					maxFieldStrength = 1000,
					energySaturation = 0,
					maxEnergySaturation = 1000,
					fuelConversion = 0,
					maxFuelConversion = 1000,
					generationRate = 0,
					fuelConversionRate = 0,
					fieldDrainRate = 0
				}
			end
			local safety = getReactorSafety(info)
			lastTemp = info.temperature
			lastShield = safety.shield
			lastSaturation = safety.saturation
			local fuelRemainingPct = 100 - ((info.fuelConversion / info.maxFuelConversion) * 100)
			if fuelRemainingPct <= 5 and not refueling and info.status ~= "cold" then
				refueling = true
				Shuttingdown = true
				reactor.stopReactor()
				inGate.setSignalLowFlow(1200000)
				outGate.setSignalLowFlow(0)
				logReactorEvent(info, targetNBT, "LOW FUEL: SHUTTING DOWN")
			end
			if refueling and fuelRemainingPct >= 95 then
				refueling = false
				if info.status == "cold" then
					inGate.setSignalLowFlow(900000)
					outGate.setSignalLowFlow(0)
					reactor.chargeReactor()
					logReactorEvent(info, targetNBT, "FUEL DETECTED: AUTO-STARTING")
				end
			end
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
				if info.status == "cold" then Shuttingdown = false end
			end
			if os.clock() - lastHourLog >= 3600 then
				logReactorEvent(info, targetNBT)
				lastHourLog = os.clock()
			end
			if safety.isCritical and not criticalLogged then
				logReactorEvent(info, targetNBT, "TERMINAL: REACTOR GOING CRITICAL")
				triggerMeltdownAlarm("REACTOR CRITICAL STATE DETECTED", lastTemp, lastShield)
				criticalLogged = true
			elseif not safety.isCritical then
				criticalLogged = false
			end
			if safety.shield <= 10 or safety.saturation <= 10 then
				forceRecovery = true
			elseif safety.shield >= 30 and safety.saturation >= 30 then
				forceRecovery = false
			end
			if info.status == "running" or info.status == "online" then
				if forceRecovery then
					outGate.setSignalLowFlow(0)
				elseif cfg.mode == "Auto8k" then
					targetNBT = adjustFuelForTempOnly(info, targetNBT)
					adjustFuelRate(info, outGate, targetNBT)
				elseif cfg.mode == "AutoNBT" then
					adjustFuelRate(info, outGate, targetNBT)
				end
			else
				outGate.setSignalLowFlow(0)
			end
			local curEpoch = os.epoch("utc")
			local elapsedSeconds = (curEpoch - lastTime) / 1000
			if info.status == "warming_up" and info.temperature >= 2000 then
				reactor.activateReactor()
			end
			lastTime = curEpoch
			table.insert(fuelBuffer, info.fuelConversionRate)
			if #fuelBuffer > 60 then table.remove(fuelBuffer, 1) end
			table.insert(tempBuffer, info.temperature)
			if #tempBuffer > 60 then table.remove(tempBuffer, 1) end
			if info.status == "running" or info.status == "online" then
				local ticksPassed = elapsedSeconds * 20
				runningTotalRF = runningTotalRF + (info.generationRate * ticksPassed)
			elseif fuelRemainingPct >= 99 then
				runningTotalRF = 0
			end
			if os.clock() - lastSave >= 60 then
				saveConfig(cfg.mode, runningTotalRF, targetNBT, shieldTarget)
				lastSave = os.clock()
			end
			local currentState = info.status .. math.floor(info.temperature) .. math.floor(runningTotalRF)
			if currentState ~= lastState or needsFullRedraw then
				lastState = currentState
				drawMainUI(term, info, cfg.mode, inGate, outGate)
				if monitor then drawMainUI(monitor, info, cfg.mode, inGate, outGate) end
				needsFullRedraw = false
			end
			local timer = os.startTimer(1)
			while true do
				local ev = {os.pullEvent()}
				if ev[1] == "timer" and ev[2] == timer then break end
				if ev[1] == "mouse_click" or ev[1] == "monitor_touch" then
					local targ = (ev[1] == "mouse_click") and term or monitor
					handleInteraction(ev[3], ev[4], info, reactor, inGate, outGate, targ, cfg)
					saveConfig(cfg.mode, runningTotalRF, targetNBT, shieldTarget)
					lastState = "" 
					break
				end
			end
		else
			if lastSetupState then
				needsFullRedraw = true
				lastSetupState = false
			end
			drawSetupUI(term, reactors, gates)
			if monitor then drawSetupUI(monitor, reactors, gates) end
			needsFullRedraw = false
			sleep(0.5)
		end
	end
end
main()
