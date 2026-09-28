-- MAME autoboot script for the IIgs Doom build.
--   PROBE_DISKS    comma separated disk images; when the loader asks for
--                  disk N (its prompt on the text page) and has ejected the
--                  old disk, image N goes in (after 2 s without an eject)
--   PROBE_SECONDS  emulated seconds to run before probing (0 = run forever)
--   PROBE_DUMP     list of ADDR:LEN in hex, comma separated
--   PROBE_SNAPS    comma separated emulated seconds for extra snapshots
--   PROBE_FASTLOAD run unthrottled until the game code runs (bank $02 on)
--   PROBE_SHR      comma separated emulated seconds: save SHR memory to
--                  build/shr_SECONDS.bin (render with tools/shrpng.py);
--                  SECONDS as written, so 58.5 gives shr_58.5.bin
--   PROBE_CLOCK    FROM,TO emulated seconds: count frames at each CPU clock
--   PROBE_PHASE    ADDR,FROM,TO: ADDR (hex) of iigs_phase (make PHASES=1); time
--                  spent in each phase from FROM to TO emulated seconds
--   PROBE_PHASETICS set: FROM and TO of PROBE_PHASE are game tics (needs PROBE_GAMETIC)
--   PROBE_PHASEADDR ADDR (hex) of iigs_phase: PROBE_PROFILE adds the phase
--   PROBE_PROFILETICS set: FROM and TO of PROBE_PROFILE are game tics
--                  (needs PROBE_GAMETIC)
--   PROBE_TRACE    comma separated ADDR (hex): in the time of PROBE_PHASE,
--                  print the game tic (PROBE_GAMETIC), A, X and _Dp[0-7]
--                  (PROBE_DP, ADDR in hex, default 9D8) each time the
--                  instruction at ADDR runs
--   PROBE_LOWWRITE FROM,TO (hex): in the time of PROBE_PHASE, print the
--                  lowest address in FROM..TO that game code writes (not
--                  the ROM, not the loader at $6000)
--   PROBE_TRACEMEM comma separated ADDR (hex): with each trace line, also
--                  print the 16-bit word at each ADDR
--   PROBE_COUNT    comma separated ADDR (hex): count the reads of each
--                  address (an instruction there is an opcode fetch) in the
--                  time of PROBE_PHASE
--   PROBE_GAMETIC  ADDR (hex) of _g_gametic, for PROBE_TICSHR
--   PROBE_TICEXIT  set: exit after the last back buffer of PROBE_TICSHR
--                  (with the PROBE_DUMP memory)
--   PROBE_TICPOKE  comma separated TIC:ADDR:VALUE (hex ADDR, VALUE): the
--                  word VALUE at ADDR as game tic TIC ends (PROBE_GAMETIC)
--   PROBE_TICPRESS comma separated TIC:KEY:TICS: the key (as PROBE_PRESS)
--                  held from the end of game tic TIC for TICS tics
--   PROBE_TICKEY   comma separated TIC:CODE:TICS: the ADB key code CODE
--                  (decimal) goes down as game tic TIC ends and up as tic
--                  TIC+TICS ends, as key bytes in the ring of I_StartTic
--                  (PROBE_ADBQ, PROBE_ADBQHEAD: the hex addresses of
--                  iigs_adbq and iigs_adbqhead); the timing does not depend
--                  on the build speed
--   PROBE_AFTERKEY SECONDS:CODE: the ADB key code CODE goes down SECONDS
--                  (emulated) after the last PROBE_TICKEY key went down,
--                  and up 0.1 s later; the keys of PROBE_TICKEY still down
--                  go up first. For a key while the game tics stand still:
--                  an open menu pauses the game (the key test closes its
--                  menu this way)
--   PROBE_TICSHR   comma separated game tics N: when the game tic counter
--                  leaves N, save the back buffer ($01:2000) with SCBs and palettes of
--                  the screen to build/tic_N.bin (render with tools/shrpng.py)
--   PROBE_PRESS    comma separated SECONDS:KEY:HOLD, KEY is the name of an
--                  emulated key such as Down Arrow, Esc, Return, Control;
--                  it is held down for HOLD seconds (the natural keyboard
--                  of PROBE_KEYS types {DOWN} as characters on the IIgs)
--   PROBE_STACKPROF FROM,TO emulated seconds: each frame, write the PC, the
--                  phase (PROBE_PHASEADDR) and every return address found on
--                  the stack (3 bytes after a JSL) to build/stackprof.txt
--   PROBE_KEYS     comma separated SECONDS:TEXT, TEXT posted with MAME codes
--                  such as {ESC} and {ENTER}
--   PROBE_EXTRA    a Lua file to run after this script (experiments)
local wait = tonumber(os.getenv("PROBE_SECONDS") or "0")
local dumps = os.getenv("PROBE_DUMP") or ""
local disks = {}
for d in string.gmatch(os.getenv("PROBE_DISKS") or "", "[^,]+") do
	table.insert(disks, d)
end
local dumpTimes = {}
for s in string.gmatch(os.getenv("PROBE_DUMPTIMES") or "", "[^,]+") do
	table.insert(dumpTimes, tonumber(s))
end
local shrTimes = {}
for t in string.gmatch(os.getenv("PROBE_SHR") or "", "[^,]+") do
	table.insert(shrTimes, t)
end
local keys = {}
for t, k in string.gmatch(os.getenv("PROBE_KEYS") or "", "([%d%.]+):([^,]+)") do
	table.insert(keys, {tonumber(t), k})
end
local snaps = {}
for s in string.gmatch(os.getenv("PROBE_SNAPS") or "", "[^,]+") do
	table.insert(snaps, tonumber(s))
end
local profFrom, profTo = string.match(os.getenv("PROBE_PROFILE") or "", "(%d+),(%d+)")
profFrom = tonumber(profFrom)
profTo = tonumber(profTo)
local profFile = nil
local profByTic = os.getenv("PROBE_PROFILETICS") ~= nil
local fastload = os.getenv("PROBE_FASTLOAD") ~= nil
local profPhase = os.getenv("PROBE_PHASEADDR") and tonumber(os.getenv("PROBE_PHASEADDR"), 16)
local clockLog = nil
local clockHist = {}
local clockItems = nil
local spFrom, spTo = string.match(os.getenv("PROBE_STACKPROF") or "", "(%d+),(%d+)")
spFrom, spTo = tonumber(spFrom), tonumber(spTo)
local spFile = nil
local presses, releases = {}, {}
for t, k, h in string.gmatch(os.getenv("PROBE_PRESS") or "", "([%d%.]+):([^:,]+):([%d%.]+)") do
	table.insert(presses, { tonumber(t), k, tonumber(h) })
end
table.sort(presses, function(a, b) return a[1] < b[1] end)

local function keyField(name)
	for _, port in pairs(manager.machine.ioport.ports) do
		local field = port.fields[name]
		if field then return field end
	end
	return nil
end
local gameticAddr = os.getenv("PROBE_GAMETIC") and tonumber(os.getenv("PROBE_GAMETIC"), 16)
local ticShr = {}
local ticExit = os.getenv("PROBE_TICEXIT") ~= nil
local ticTap = nil
for t in string.gmatch(os.getenv("PROBE_TICSHR") or "", "[^,]+") do
	table.insert(ticShr, tonumber(t))
end
local ticPokes, ticPresses, ticReleases = {}, {}, {}
for t, a, v in string.gmatch(os.getenv("PROBE_TICPOKE") or "", "(%d+):(%x+):(%x+)") do
	table.insert(ticPokes, { tonumber(t), tonumber(a, 16), tonumber(v, 16) })
end
for t, k, h in string.gmatch(os.getenv("PROBE_TICPRESS") or "", "(%d+):([^:,]+):(%d+)") do
	table.insert(ticPresses, { tonumber(t), k, tonumber(h) })
end
local ticKeys = {}
for t, c, h in string.gmatch(os.getenv("PROBE_TICKEY") or "", "(%d+):(%d+):(%d+)") do
	table.insert(ticKeys, { tonumber(t), tonumber(c), tonumber(h) })
end
local adbqAddr = os.getenv("PROBE_ADBQ") and tonumber(os.getenv("PROBE_ADBQ"), 16)
local adbqHeadAddr = os.getenv("PROBE_ADBQHEAD") and tonumber(os.getenv("PROBE_ADBQHEAD"), 16)
if #ticKeys > 0 and not (adbqAddr and adbqHeadAddr) then
	error("PROBE_TICKEY needs PROBE_ADBQ and PROBE_ADBQHEAD")
end
local afterSec, afterCode = string.match(os.getenv("PROBE_AFTERKEY") or "", "([%d%.]+):(%d+)")
afterSec, afterCode = tonumber(afterSec), tonumber(afterCode)
local lastTicKeyAt, afterUpAt = nil, nil
-- a key byte into the ring of I_StartTic (32 bytes)
local function adbPush(space, byte)
	local head = space:read_u16(adbqHeadAddr)
	space:write_u8(adbqAddr + head, byte)
	space:write_u16(adbqHeadAddr, (head + 1) % 32)
end
local phaseAddr, phaseFrom, phaseTo = string.match(os.getenv("PROBE_PHASE") or "", "(%x+),(%d+),(%d+)")
local phaseTime, phaseCount, phaseCur, phaseAt = {}, {}, 0, nil
local phaseTap = nil
local phaseByTic = os.getenv("PROBE_PHASETICS") ~= nil
local phaseLow = nil
local countAddrs, countTaps, counts = {}, {}, {}
for a in string.gmatch(os.getenv("PROBE_COUNT") or "", "%x+") do
	table.insert(countAddrs, tonumber(a, 16))
end
local traceAddrs, traceTaps = {}, {}
local dpAddr = tonumber(os.getenv("PROBE_DP") or "9D8", 16)
for a in string.gmatch(os.getenv("PROBE_TRACE") or "", "%x+") do
	table.insert(traceAddrs, tonumber(a, 16))
end
local lowFrom, lowTo = string.match(os.getenv("PROBE_LOWWRITE") or "", "(%x+),(%x+)")
local lowTap, lowest = nil, nil
local traceMem = {}
for a in string.gmatch(os.getenv("PROBE_TRACEMEM") or "", "%x+") do
	table.insert(traceMem, tonumber(a, 16))
end
do
	local a, b = string.match(os.getenv("PROBE_CLOCK") or "", "(%d+),(%d+)")
	if a then clockLog = { tonumber(a), tonumber(b) } end
end
if fastload then manager.machine.video.throttled = false end
local done = false
local lastAsked = 0
local askedAt = nil

local function hexdump(space, addr, len)
	for base = addr, addr + len - 1, 16 do
		local line = string.format("%06X:", base)
		for i = 0, 15 do
			if base + i < addr + len then
				line = line .. string.format(" %02X", space:read_u8(base + i))
			end
		end
		print(line)
	end
end

local function floppy()
	for tag, img in pairs(manager.machine.images) do
		if string.find(tag, "35dd") and string.find(tag, "fdc:2") then
			return img
		end
	end
	return nil
end

-- Row 18, column 4 of the 40 column text page holds the loader prompt.
local function askedDisk(space)
	local base = 0xe00550 + 4
	local text = ""
	for i = 0, 12 do
		text = text .. string.char(space:read_u8(base + i) & 0x7f)
	end
	if text == "INSERT DISK 1" or string.sub(text, 1, 12) == "INSERT DISK " then
		return tonumber(string.sub(text, 13, 13))
	end
	return nil
end

-- PROBE_TAG: a label of the build in the top right corner of the window
-- (for the windows of tools/watch.sh), drawn over the emulated screen.
local buildTag = os.getenv("PROBE_TAG")

emu.register_frame_done(function()
	if buildTag then
		manager.machine.screens[":screen"]:draw_text("right", 0, buildTag, 0xffffff00, 0xc0000000)
	end
	if done then return end
	local now = manager.machine.time:as_double()
	local cpu = manager.machine.devices[":maincpu"]
	local space = cpu.spaces["program"]

	if afterSec and lastTicKeyAt and afterUpAt == nil then
		local pending = false
		for _, k in ipairs(ticKeys) do
			if not k[4] then pending = true end
		end
		if not pending and now >= lastTicKeyAt + afterSec then
			for i = #ticKeys, 1, -1 do
				adbPush(space, ticKeys[i][2] | 0x80)
				table.remove(ticKeys, i)
			end
			adbPush(space, afterCode)
			afterUpAt = now + 0.1
			print(string.format("[probe] %.2fs: key %d (PROBE_AFTERKEY)", now, afterCode))
		end
	elseif afterUpAt and afterUpAt > 0 and now >= afterUpAt then
		adbPush(space, afterCode | 0x80)
		afterUpAt = -1
	end

	local phaseClock = now
	if phaseByTic then
		phaseClock = space:read_u32(gameticAddr)
	end
	if phaseAddr and not phaseTap and phaseClock >= tonumber(phaseFrom) then
		phaseAt = manager.machine.time:as_double()
		phaseLow = tonumber(phaseAddr, 16)
		phaseTap = space:install_write_tap(tonumber(phaseAddr, 16), tonumber(phaseAddr, 16) + 1, "phase",
			function(offset, data, mask)
				if offset ~= phaseLow then return end
				local t = manager.machine.time:as_double()
				phaseTime[phaseCur] = (phaseTime[phaseCur] or 0) + (t - phaseAt)
				phaseCount[phaseCur] = (phaseCount[phaseCur] or 0) + 1
				phaseAt = t
				phaseCur = data & 0xff
			end)
		if lowFrom then
			lowTap = space:install_write_tap(tonumber(lowFrom, 16), tonumber(lowTo, 16), "lowwrite",
				function(offset, data, mask)
					local st = manager.machine.devices[":maincpu"].state
					local pb, pc = st["PB"].value, st["PC"].value
					if pb >= 0xe0 or (pb == 0 and pc >= 0x6000) then return end
					if not lowest or offset < lowest then lowest = offset end
				end)
		end
		for i, a in ipairs(countAddrs) do
			counts[i] = 0
			countTaps[i] = space:install_read_tap(a, a, "count" .. i,
				function(offset, data, mask)
					if offset == a then counts[i] = counts[i] + 1 end
				end)
		end
		for i, a in ipairs(traceAddrs) do
			traceTaps[i] = space:install_read_tap(a, a, "trace" .. i,
				function(offset, data, mask)
					if offset ~= a then return end
					local st = manager.machine.devices[":maincpu"].state
					local dp = ""
					for k = 0, 7 do dp = dp .. string.format(" %02X", space:read_u8(dpAddr + k)) end
					if #traceMem > 0 then
						dp = dp .. " M:"
						for _, m in ipairs(traceMem) do dp = dp .. string.format(" %04X", space:read_u16(m)) end
					end
					local tic = gameticAddr and space:read_u32(gameticAddr) or 0
					print(string.format("[probe] trace %06X %.3fs tic %d A=%04X X=%04X Dp:%s", a,
						manager.machine.time:as_double(), tic, st["A"].value, st["X"].value, dp))
				end)
		end
	end
	if phaseTap and phaseAddr and phaseClock >= tonumber(phaseTo) then
		phaseTap:remove()
		phaseTime[phaseCur] = (phaseTime[phaseCur] or 0) + (manager.machine.time:as_double() - phaseAt)
		local total = 0
		for _, v in pairs(phaseTime) do total = total + v end
		for k = 0, 15 do
			if phaseTime[k] then
				print(string.format("[probe] phase %2d: %7.2fs %5.1f%% %6d entries", k, phaseTime[k],
					100 * phaseTime[k] / total, phaseCount[k] or 0))
			end
		end
		print(string.format("[probe] phases: %.2fs from %s to %s", total, phaseFrom, phaseTo))
		for i, a in ipairs(countAddrs) do
			countTaps[i]:remove()
			print(string.format("[probe] count %06X: %d", a, counts[i]))
		end
		for i, _ in ipairs(traceAddrs) do
			traceTaps[i]:remove()
		end
		if lowTap then
			lowTap:remove()
			print(string.format("[probe] count lowest write %s", lowest and string.format("%06X", lowest) or "none"))
		end
		phaseAddr = nil
		if phaseByTic then
			done = true
			manager.machine:exit()
			return
		end
	end

	if clockLog and now >= clockLog[1] then
		if now < clockLog[2] then
			if not clockItems then
				local drv = manager.machine.devices[":"]
				clockItems = {
					emu.item(cpu.items["0/m_unscaled_clock"]),
					emu.item(drv.items["0/m_accel_temp_slowdown"]),
					emu.item(drv.items["0/m_speed"]),
					emu.item(drv.items["0/m_accel_fast"]),
				}
			end
			local c = string.format("%d Hz, temp slowdown %d, speed reg %02X, accel %d",
				clockItems[1]:read(0), clockItems[2]:read(0), clockItems[3]:read(0), clockItems[4]:read(0))
			clockHist[c] = (clockHist[c] or 0) + 1
		elseif not clockLog.done then
			clockLog.done = true
			for c, n in pairs(clockHist) do
				print(string.format("[probe] clock %s: %d frames", c, n))
			end
		end
	end

	if #disks > 0 then
		local n = askedDisk(space)
		if n and n ~= lastAsked and disks[n] then
			local img = floppy()
			if img then
				askedAt = askedAt or now
				if not img.exists or now - askedAt > 2.0 then
					print(string.format("[probe] %.1fs inserted disk %d (%s)", now, n,
						img.exists and "the drive did not eject" or "after the eject"))
					img:load(disks[n])
					lastAsked = n
					askedAt = nil
				end
			end
		end
	end

	if spFrom and now >= spFrom and now < spTo then
		if not spFile then spFile = io.open("build/stackprof.txt", "w") end
		local sp = cpu.state["S"].value
		local line = {string.format("%06X", cpu.state["PC"].value | (cpu.state["PB"].value << 16))}
		line[#line + 1] = tostring(profPhase and space:read_u8(profPhase) or 0)
		-- scan the stack: a JSL pushes the address of its last byte
		for a = sp + 1, 0x3ffd do
			local ret = space:read_u8(a) | (space:read_u8(a + 1) << 8) | (space:read_u8(a + 2) << 16)
			if ((ret >= 0x030000 and ret < 0x080000) or (ret >= 0x004000 and ret < 0x006000))
					and space:read_u8(ret - 3) == 0x22 then
				line[#line + 1] = string.format("%06X", ret)
			end
		end
		spFile:write(table.concat(line, " ") .. "\n")
	elseif spFile and spTo and now >= spTo then
		spFile:close()
		spFile = nil
		spFrom = nil
		print("[probe] stack profile written")
	end

	local profClock = now
	if profByTic and gameticAddr then profClock = space:read_u32(gameticAddr) end
	if profFrom and profClock >= profFrom and profClock < profTo then
		if not profFile then profFile = io.open("build/profile.txt", "w") end
		local sp = cpu.state["S"].value
		local ret = space:read_u8(sp + 1) | (space:read_u8(sp + 2) << 8) | (space:read_u8(sp + 3) << 16)
		local phase = profPhase and space:read_u8(profPhase) or 0
		profFile:write(string.format("%06X %06X %d\n", cpu.state["PC"].value | (cpu.state["PB"].value << 16), ret, phase))
	elseif profFile and profClock >= profTo then
		profFile:close()
		profFile = nil
		profFrom = nil
		print("[probe] profile written")
		if profByTic then
			manager.machine:exit()
			return
		end
	end

	local pb = cpu.state["PB"].value
	if fastload and pb >= 0x02 and pb < 0xe0 then
		manager.machine.video.throttled = true
		fastload = false
		print(string.format("[probe] %.1fs game started, normal speed", now))
	end

	if #dumpTimes > 0 and now >= dumpTimes[1] then
		print(string.format("[probe] %.1fs PC=%X", now, cpu.state["PC"].value))
		for spec in string.gmatch(dumps, "[^,]+") do
			local a, l = string.match(spec, "(%x+):(%x+)")
			if a then hexdump(space, tonumber(a, 16), tonumber(l, 16)) end
		end
		table.remove(dumpTimes, 1)
	end

	if #presses > 0 and now >= presses[1][1] then
		local p = table.remove(presses, 1)
		local field = keyField(p[2])
		if field then
			field:set_value(1)
			table.insert(releases, { now + p[3], field })
			print(string.format("[probe] %.1fs press %s", now, p[2]))
		else
			print("[probe] no key " .. p[2])
		end
	end
	for i = #releases, 1, -1 do
		if now >= releases[i][1] then
			releases[i][2]:clear_value()
			table.remove(releases, i)
		end
	end

	if #keys > 0 and now >= keys[1][1] then
		manager.machine.natkeyboard:post_coded(keys[1][2])
		print(string.format("[probe] %.1fs key %s", now, keys[1][2]))
		table.remove(keys, 1)
	end

	if gameticAddr and (#ticShr > 0 or #ticPokes > 0 or #ticPresses > 0 or #ticKeys > 0) and not ticTap then
		-- The tap runs before the increment is stored, so the back buffer
		-- holds the complete frame of the old tic
		ticTap = space:install_write_tap(gameticAddr, gameticAddr, "tic",
			function(offset, data, mask)
				if offset ~= gameticAddr then return end
				local old = space:read_u32(gameticAddr)
				-- PROBE_TICPOKE: a word written as tic N ends
				for i = #ticPokes, 1, -1 do
					if old >= ticPokes[i][1] then
						space:write_u16(ticPokes[i][2], ticPokes[i][3])
						print(string.format("[probe] tic %d: %06X = %04X", old, ticPokes[i][2], ticPokes[i][3]))
						table.remove(ticPokes, i)
					end
				end
				-- PROBE_TICPRESS: a key held from the end of tic N for H tics
				for i = #ticReleases, 1, -1 do
					if old >= ticReleases[i][1] then
						ticReleases[i][2]:clear_value()
						table.remove(ticReleases, i)
					end
				end
				-- PROBE_TICKEY: key down as tic TIC ends, up as tic
				-- TIC+TICS ends
				for i = #ticKeys, 1, -1 do
					local k = ticKeys[i]
					if k[4] == nil and old >= k[1] then
						adbPush(space, k[2])
						k[4] = true
						lastTicKeyAt = manager.machine.time:as_double()
						print(string.format("[probe] tic %d: key %d for %d tics", old, k[2], k[3]))
					end
					if k[4] and old >= k[1] + k[3] then
						adbPush(space, k[2] | 0x80)
						table.remove(ticKeys, i)
					end
				end
				for i = #ticPresses, 1, -1 do
					if old >= ticPresses[i][1] then
						local field = keyField(ticPresses[i][2])
						if field then
							field:set_value(1)
							table.insert(ticReleases, { old + ticPresses[i][3], field })
							print(string.format("[probe] tic %d: press %s", old, ticPresses[i][2]))
						end
						table.remove(ticPresses, i)
					end
				end
				if #ticShr == 0 then return end
				if old < ticShr[1] then return end
				local f = io.open(string.format("build/tic_%d.bin", ticShr[1]), "wb")
				local parts = {}
				for a = 0x012000, 0x019cff do
					parts[#parts + 1] = string.char(space:read_u8(a))
				end
				for a = 0xe19d00, 0xe19fff do
					parts[#parts + 1] = string.char(space:read_u8(a))
				end
				f:write(table.concat(parts))
				f:close()
				print(string.format("[probe] %.1fs tic %d: back buffer saved (tic %d)", manager.machine.time:as_double(), ticShr[1], old))
				table.remove(ticShr, 1)
				if #ticShr == 0 and ticExit then
					for spec in string.gmatch(dumps, "[^,]+") do
						local da, dl = string.match(spec, "(%x+):(%x+)")
						if da then hexdump(space, tonumber(da, 16), tonumber(dl, 16)) end
					end
					done = true
					manager.machine:exit()
				end
			end)
	end

	if #shrTimes > 0 and now >= tonumber(shrTimes[1]) then
		local f = io.open(string.format("build/shr_%s.bin", shrTimes[1]), "wb")
		local parts = {}
		for a = 0xe12000, 0xe19fff do
			parts[#parts + 1] = string.char(space:read_u8(a))
		end
		f:write(table.concat(parts))
		f:close()
		print(string.format("[probe] %.1fs SHR saved", now))
		table.remove(shrTimes, 1)
	end

	if #snaps > 0 and now >= snaps[1] then
		manager.machine.video:snapshot()
		print(string.format("[probe] %.1fs snapshot", now))
		table.remove(snaps, 1)
	end

	if wait == 0 or now < wait then return end
	done = true
	local st = cpu.state
	local names = { "PC", "PB", "A", "X", "Y", "S", "D", "DB", "P", "E" }
	local line = ""
	for _, n in ipairs(names) do
		if st[n] then line = line .. string.format("%s=%X ", n, st[n].value) end
	end
	print(line)
	for spec in string.gmatch(dumps, "[^,]+") do
		local a, l = string.match(spec, "(%x+):(%x+)")
		if a then hexdump(space, tonumber(a, 16), tonumber(l, 16)) end
	end
	manager.machine.video:snapshot()
	manager.machine:exit()
end)

local extra = os.getenv("PROBE_EXTRA")
if extra then dofile(extra) end
