#!/usr/bin/env python3
"""Build the Pocket .rom image for the Punch-Out!! core from a MAME romset.

A core is FPGA gateware: it cannot unzip a romset or run a script, so the ROM
image has to be assembled on a computer. This reads the .mra description and a
MAME `punchout` romset -- either the zip or a directory of loose files -- checks
every part's CRC32, concatenates them in the order the .mra gives, and verifies
the finished image against the md5 recorded in the .mra.

Punch-Out!! needs two things a plain concatenation cannot express, both of which
the standard MRA format already covers and both of which are implemented here:

  <part name="x" crc="y" offset="0x1000" length="0x800"/>
        one slice of a ROM. Eight of the graphics ROMs are read back in the
        order 0, 2, 1, 3 by quarters (MAME's ROM_CONTINUE chain), so each
        appears four times.

  <part repeat="0x2000">FF</part>
  <part name="x.rom" crc="12345678" invert="1"/>   ROMREGION_INVERT
        a run of literal bytes. The big-sprite ROM boards have unpopulated
        sockets that read as 0xFF, and keeping those gaps in the image is what
        lets a tile code address the data with a shift and an add.

Nothing but Python 3 is required. The same .mra also works with the standard
MiSTer mra tools if you already have them.

Usage:
    mra_build.py <file.mra> <romset.zip|romset_dir> [out.rom]
    mra_build.py punchout.mra punchout.zip
    mra_build.py punchout.mra ~/roms/punchout/
"""
import sys, os, zipfile, hashlib, zlib
import xml.etree.ElementTree as ET


def load_parts(path):
    """Map lowercase member name -> bytes, from a zip or a directory."""
    out = {}
    if os.path.isdir(path):
        for entry in os.scandir(path):
            if entry.is_file():
                with open(entry.path, 'rb') as f:
                    out[entry.name.lower()] = f.read()
        if not out:
            sys.exit(f'error: {path} contains no files')
        return out

    if not os.path.exists(path):
        sys.exit(f'error: {path} not found')
    try:
        with zipfile.ZipFile(path) as zf:
            for info in zf.infolist():
                if not info.is_dir():
                    out[os.path.basename(info.filename).lower()] = zf.read(info)
    except zipfile.BadZipFile:
        sys.exit(f'error: {path} is neither a directory nor a readable zip')
    return out


def literal_bytes(node):
    """<part repeat="N">FF</part> and <part>0A 0B</part> -- a run of literals.

    The text is whitespace-separated hex byte pairs; repeat defaults to 1.
    """
    text = (node.text or '').split()
    if not text:
        sys.exit('error: <part> with no name and no body')
    try:
        pattern = bytes(int(tok, 16) for tok in text)
    except ValueError:
        sys.exit(f'error: <part> body is not hex bytes: {node.text!r}')
    repeat = int(node.get('repeat', '1'), 0)
    return f'<fill {pattern.hex()} x{repeat}>', pattern * repeat


def get_part(parts, node):
    name = node.get('name')
    if name is None:
        return literal_bytes(node)

    data = parts.get(name.lower())
    if data is None:
        sys.exit(f'error: {name} missing from the romset')

    # The CRC in the mra is the CRC of the whole ROM, not of the slice, so it
    # is checked before slicing. A ROM that appears as several slices gets
    # checked several times, which costs nothing and keeps each <part> able to
    # stand on its own.
    crc = node.get('crc')
    if crc is not None:
        actual = zlib.crc32(data) & 0xffffffff
        if actual != int(crc, 16):
            sys.exit(f'error: {name} CRC {actual:08x}, expected {int(crc, 16):08x} '
                     '(wrong romset, or a bad dump)')

    off = int(node.get('offset', '0'), 0)
    length = node.get('length')
    if length is None:
        sliced = data[off:]
    else:
        n = int(length, 0)
        sliced = data[off:off + n]
        if len(sliced) != n:
            sys.exit(f'error: {name} is {len(data)} bytes, too short for '
                     f'offset 0x{off:x} length 0x{n:x}')

    # invert="1" is our own attribute, for a region MAME marks
    # ROMREGION_INVERT: Arm Wrestling's big-sprite #2 ROMs are stored with
    # every bit flipped. Doing it here keeps one graphics path in the core for
    # all three games.
    if node.get('invert') in ('1', 'true', 'yes'):
        sliced = bytes(b ^ 0xff for b in sliced)
    return name, sliced


def build(mra_path, romset_path, verbose=False):
    root = ET.parse(mra_path).getroot()
    rom = next((r for r in root.iter('rom') if r.get('index', '0') == '0'), None)
    if rom is None:
        sys.exit('error: no <rom index="0"> in the mra file')

    parts = load_parts(romset_path)
    image = bytearray()
    for node in rom:
        if node.tag is ET.Comment:
            continue
        if node.tag != 'part':
            sys.exit(f'error: <{node.tag}> inside <rom> is not supported by this builder')
        name, data = get_part(parts, node)
        if verbose:
            print(f'  0x{len(image):06X}  {len(data):6d}  {name}')
        image += data

    got = hashlib.md5(image).hexdigest()
    want = rom.get('md5')
    if want and want.lower() not in ('none', 'ignore') and got != want.lower():
        sys.exit(f'error: built image md5 {got}, expected {want}\n'
                 '       the romset does not match the one this core was verified against')
    return bytes(image), got


def main():
    args = [a for a in sys.argv[1:] if a != '-v']
    verbose = '-v' in sys.argv[1:]
    if len(args) < 2:
        sys.exit(__doc__)
    mra, romset = args[0], args[1]
    out = args[2] if len(args) > 2 else None
    if out is None:
        root = ET.parse(mra).getroot()
        # setname is the MAME romset name, which is also what data.json asks
        # the Pocket to look for -- so the default output needs no renaming.
        name = root.findtext('setname') or root.findtext('name') or 'output'
        out = name.lower().replace(' ', '_') + '.rom'

    if verbose:
        print(f'{mra} + {romset}:')
    image, md5 = build(mra, romset, verbose)
    with open(out, 'wb') as f:
        f.write(image)
    print(f'wrote {out} ({len(image)} bytes, md5 {md5}) - verified')
    print('copy it to  Assets/punchout/common/  on your Pocket SD card')


if __name__ == '__main__':
    main()
