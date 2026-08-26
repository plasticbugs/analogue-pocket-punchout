-- Log every write the game makes to a memory range, tagged with the frame, in
-- order. Run from a directory holding roms/punchout.zip:
--   mame punchout -rompath roms -video none -sound none -nothrottle -autoboot_script tools/writetap.lua
-- Handles are globals on purpose: a tap whose handle is collected is removed.
-- Nothing but the write itself happens inside the tap (no vpos, no time).
local mach = manager.machine
local sp = mach.devices[":maincpu"].spaces["program"]
local ports = mach.ioport.ports
local coin = ports[":IN1"].fields["Coin 1"]
local b1 = ports[":IN0"].fields["P1 Button 1"]
frame = 0
nwr = 0
wf = assert(io.open("wtap.bin", "wb"))
-- global: a tap handle that is collected is a tap that is removed
tap_bot = sp:install_write_tap(0xf000, 0xffff, "wt_bot", function(offset, data, mask)
  if frame >= 7000 and frame <= 10500 then
    wf:write(string.pack("<I2I2B", frame, offset, data & 0xff)); nwr = nwr + 1
  end
end)
tap_ctl = sp:install_write_tap(0xdff0, 0xdffd, "wt_ctl", function(offset, data, mask)
  if frame >= 7000 and frame <= 10500 then
    wf:write(string.pack("<I2I2B", frame, offset, data & 0xff)); nwr = nwr + 1
  end
end)
emu.register_frame_done(function()
  frame = frame + 1
  coin:set_value((frame >= 200 and frame < 206) and 1 or 0)
  b1:set_value(((frame >= 700 and frame < 706) or (frame >= 900 and frame < 906) or (frame >= 1100 and frame < 1106)) and 1 or 0)
  if frame % 1000 == 0 then print(string.format("[wtap] frame %d, %d writes logged", frame, nwr)) end
  if frame > 10500 then wf:close(); mach:exit() end
end)
