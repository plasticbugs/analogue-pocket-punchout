-- every access to the protection ports 05-07, with the frame
local m = manager.machine
local iosp = m.devices[":maincpu"].spaces["io"]
frame = 0
wf = assert(io.open("prot.bin", "wb"))
nrd = 0; nwr = 0
tap_w = iosp:install_write_tap(0x00, 0xff, "pw", function(offset, data, mask)
  local p = offset & 0xff
  if (p & 0x0f) >= 5 and (p & 0x0f) <= 7 then
    wf:write(string.pack("<I2BBB", frame, 0, p, data & 0xff)); nwr = nwr + 1
  end
end)
tap_r = iosp:install_read_tap(0x00, 0xff, "pr", function(offset, data, mask)
  local p = offset & 0xff
  if (p & 0x0f) >= 5 and (p & 0x0f) <= 7 then
    wf:write(string.pack("<I2BBB", frame, 1, p, data & 0xff)); nrd = nrd + 1
  end
end)
emu.register_frame_done(function()
  frame = frame + 1
  if frame % 600 == 0 then print(string.format("[prot] frame %d: %d reads %d writes", frame, nrd, nwr)) end
  if frame > 1800 then wf:close(); m:exit() end
end)
