local m = manager.machine
local snd = m.devices[":audiocpu"].spaces["program"]
frame = 0
wf = assert(io.open("apucyc.bin", "wb"))
tap = snd:install_write_tap(0x4000, 0x4017, "apu_w", function(offset, data, mask)
  local t = m.time                       -- emulated time of this write
  local att = t.seconds * 1000000 + (t.attoseconds // 1000000000000)  -- microseconds
  wf:write(string.pack("<i8I2B", att, offset, data & 0xff))
end)
emu.register_frame_done(function()
  frame = frame + 1
  if frame > 1500 then wf:close(); m:exit() end
end)
