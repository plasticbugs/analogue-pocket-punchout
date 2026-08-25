-- Dump one frozen Punch-Out!! video state plus the MAME snapshot of exactly
-- that state.
--
-- punchout.cpp never calls update_partial, so MAME renders both monitors once,
-- from whatever the video RAM holds at the end of the frame. That makes a
-- static renderer a fair model of it -- provided the state we write out is the
-- state MAME drew from.
--
-- So: copy every byte the renderer reads into Lua tables, then install write
-- taps over the same ranges that hand back the saved byte, cancelling any
-- further change. The CPUs keep running; the picture stops moving. Two frames
-- later the taps are checked against memory (a tap that never fires would be a
-- silent lie, and METHODOLOGY 5.1 says check the instrument), then the state is
-- written and MAME is asked for a snapshot of it.
--
-- usage: PO_FRAME=900 PO_TAG=0900 mame punchout -autoboot_script tools/dumpstate.lua

local OUT    = os.getenv("PO_OUT")   or "artifacts"
local TARGET = tonumber(os.getenv("PO_FRAME") or "900")
local TAG    = os.getenv("PO_TAG")   or string.format("%04d", TARGET)
-- The game never touched the palette bank in 9000 frames of scanned play, so
-- the only way to cover that path is to set it by hand after freezing. The
-- frozen byte and the RAM are both updated, so MAME renders what we dump.
local PALBANK = tonumber(os.getenv("PO_PALBANK") or "")

local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]

-- Everything screen_update_punchout_{top,bottom} reads, as three contiguous
-- CPU-visible blocks. d800-dfff carries the top tilemap AND the two big-sprite
-- control blocks AND the palette bank; f000-f03f is the bottom map's per-row
-- scroll table as well as being tilemap row 0.
local REGIONS = {
    { name = "VRAM_D800", lo = 0xd800, len = 0x0800 },  -- bg_top + spr ctrl + palettebank
    { name = "VRAM_E000", lo = 0xe000, len = 0x1000 },  -- spr1 (opponent) + spr2 (player)
    { name = "VRAM_F000", lo = 0xf000, len = 0x1000 },  -- bg_bot + row scroll
}

local FROZEN = {}

local ports = mach.ioport.ports
local function field(p, n) local q = ports[p]; return q and q.fields[n] or nil end
local coin  = field(":IN1", "Coin 1")
local b1    = field(":IN0", "P1 Button 1")
local b2    = field(":IN0", "P1 Button 2")
local b3    = field(":IN0", "P1 Button 3")
local up    = field(":IN1", "P1 Up")
local down  = field(":IN1", "P1 Down")
local left  = field(":IN1", "P1 Left")
local right = field(":IN1", "P1 Right")

local frame, frozen_at = 0, nil
local function hold(f, on) if f then f:set_value(on and 1 or 0) end end

local function freeze()
    for _, r in ipairs(REGIONS) do
        local t = {}
        for i = 0, r.len - 1 do t[i] = sp:read_u8(r.lo + i) end
        FROZEN[r.name] = t
        local lo, hi = r.lo, r.lo + r.len - 1
        sp:install_write_tap(lo, hi, "frz_" .. r.name, function(offset, data, mask)
            return t[offset - lo] or data
        end)
    end
    if PALBANK then
        FROZEN["VRAM_D800"][0x7fd] = PALBANK
        sp:write_u8(0xdffd, PALBANK)
        print(string.format("[po] palettebank forced to %d", PALBANK))
    end
    print(string.format("[po] video state frozen at frame %d", frame))
end

-- A tap that silently never fires would leave the dump describing a frame MAME
-- did not draw, and the diff would blame the renderer. Check it instead.
local function verify()
    local bad = 0
    for _, r in ipairs(REGIONS) do
        local t = FROZEN[r.name]
        for i = 0, r.len - 1 do
            if sp:read_u8(r.lo + i) ~= t[i] then bad = bad + 1 end
        end
    end
    if bad > 0 then
        print(string.format("[po] WARNING: %d bytes moved after freezing -- the write "
                            .. "taps are not holding, and the dump will not match the snapshot", bad))
    end
    return bad
end

local function dump()
    local drift = verify()
    local f = assert(io.open(string.format("%s/state_%s.txt", OUT, TAG), "w"))
    f:write(string.format("frame %d\n", frozen_at))
    f:write(string.format("drift %d\n", drift))
    for _, r in ipairs(REGIONS) do
        f:write(r.name, "\n")
        local t, line = FROZEN[r.name], {}
        for i = 0, r.len - 1 do
            line[#line + 1] = string.format("%02x", t[i])
            if #line == 32 then f:write(table.concat(line), "\n"); line = {} end
        end
        if #line > 0 then f:write(table.concat(line), "\n") end
    end
    f:write("END\n")
    f:close()

    -- MAME's dual-screen snapshot goes through the layout and resamples the
    -- bottom monitor, which shows up as hundreds of near-miss colours that have
    -- nothing to do with the renderer. screen:pixels() is the bitmap itself:
    -- native size, no filtering, and the only thing worth diffing against.
    for _, s in ipairs({ { "top", ":top" }, { "bot", ":bottom" } }) do
        local scr = mach.screens[s[2]]
        local g = assert(io.open(string.format("%s/pix_%s_%s.bin", OUT, s[1], TAG), "wb"))
        g:write((scr:pixels()))   -- extra parens: pixels() also returns w,h
        g:close()
    end
    mach.video:snapshot()          -- kept for eyeballing, not for diffing
    print(string.format("[po] dumped %s", TAG))
    mach:exit()
end

emu.register_frame_done(function()
    frame = frame + 1
    if frozen_at then
        if frame == frozen_at + 2 then dump() end
        return
    end

    -- There is no start button: a coin begins play. After that, punch and move
    -- on a few coprime periods so successive target frames land on genuinely
    -- different situations rather than the same pose over and over.
    hold(coin, frame >= 200 and frame < 206)
    if frame > 400 then
        hold(b1,    (frame // 23) % 3 == 0)
        hold(b2,    (frame // 31) % 4 == 0)
        hold(b3,    (frame // 97) % 7 == 0)
        hold(up,    (frame // 53) % 5 == 0)
        hold(down,  (frame // 67) % 6 == 0)
        hold(left,  (frame // 41) % 4 == 1)
        hold(right, (frame // 41) % 4 == 3)
    end

    if frame == TARGET then freeze(); frozen_at = frame end
end)

print("[po] dumpstate.lua armed for frame " .. TARGET)
