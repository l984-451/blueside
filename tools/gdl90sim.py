#!/usr/bin/env python3
"""Sends GDL 90 like an ADS-B receiver: heartbeat, device ID, ownship and a few targets around KBHM, once a second.

iOS simulator:     python3 tools/gdl90sim.py
Android emulator:  python3 tools/gdl90sim.py --android   (redirects host UDP 4000 into the emulator first)
Without ownship (the device's GPS places the aircraft):  --no-ownship
"""
import argparse
import math
import socket
import subprocess
import time

KBHM = (33.5629, -86.7535)
OWN_ALT = 3500


def crc(data):
    table = []
    for i in range(256):
        c = i << 8
        for _ in range(8):
            c = ((c << 1) ^ (0x1021 if c & 0x8000 else 0)) & 0xFFFF
        table.append(c)
    value = 0
    for b in data:
        value = (table[value >> 8] ^ (value << 8) ^ b) & 0xFFFF
    return value


def frame(message):
    c = crc(message)
    out = bytearray([0x7E])
    for b in bytes(message) + bytes([c & 0xFF, c >> 8]):
        out += bytes([0x7D, b ^ 0x20]) if b in (0x7D, 0x7E) else bytes([b])
    return bytes(out + b"\x7e")


def semicircles(degrees):
    v = int(round(degrees * (1 << 23) / 180)) & 0xFFFFFF
    return bytes([v >> 16, (v >> 8) & 0xFF, v & 0xFF])


def report(msg_id, address, lat, lon, alt_ft, track, knots, fpm, callsign, emitter=1):
    alt = (alt_ft + 1000) // 25
    v = (fpm // 64) & 0xFFF
    misc = 0x09  # airborne, true track
    name = (callsign + " " * 8)[:8].encode()
    return (bytes([msg_id, 0x00, address >> 16, (address >> 8) & 0xFF, address & 0xFF])
            + semicircles(lat) + semicircles(lon)
            + bytes([alt >> 4, ((alt & 0xF) << 4) | misc, 0x89, knots >> 4, ((knots & 0xF) << 4) | (v >> 8), v & 0xFF,
                     int(track * 256 / 360) & 0xFF, emitter])
            + name + b"\x00")


def heartbeat(now):
    seconds = int(now) % 86400
    return bytes([0x00, 0x81, 0x01 | ((seconds >> 16) << 7), seconds & 0xFF, (seconds >> 8) & 0xFF, 0, 0])


def device_id():
    return (bytes([0x65, 0x00, 0x01]) + b"\xff" * 8 + b"Sim GDL " + b"Blueside Sim    " + bytes([0, 0, 0, 1]))


def geo_altitude(feet):
    v = (feet // 5) & 0xFFFF
    return bytes([0x0B, v >> 8, v & 0xFF, 0x00, 0x0A])


def offset(origin, bearing, nm):
    lat = origin[0] + nm / 60 * math.cos(math.radians(bearing))
    lon = origin[1] + nm / 60 * math.sin(math.radians(bearing)) / math.cos(math.radians(origin[0]))
    return lat, lon


def scene(t):
    """Ownship circles KBHM at 4 nm; targets keep set offsets from it so the picture stays the same."""
    angle = (t * 1.5) % 360
    own = offset(KBHM, angle, 4)
    own_track = (angle + 90) % 360
    targets = [
        # address, bearing from ownship, range nm, relative ft, track, knots, fpm, callsign
        (0xA1B2C3, own_track + 30, 1.2, 300, own_track + 200, 110, -700, "N123AB"),  # alert
        (0xA2B3C4, own_track - 60, 4.0, 900, own_track, 140, 0, "N456CD"),           # proximate
        (0xA3B4C5, own_track + 150, 9.0, -2200, own_track + 40, 220, 1200, "SWA1234"),
        (0xA4B5C6, own_track + 260, 11.0, 4500, own_track + 180, 300, 0, "DAL88"),
    ]
    out = []
    for address, bearing, nm, rel, track, knots, fpm, callsign in targets:
        lat, lon = offset(own, bearing % 360, nm)
        out.append(report(0x14, address, lat, lon, OWN_ALT + rel, track % 360, knots, fpm, callsign))
    return own, own_track, out


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=4000)
    p.add_argument("--android", action="store_true", help="adb emu redir add udp:PORT:PORT, then send to localhost")
    p.add_argument("--serial", default="emulator-5584", help="adb serial for --android")
    p.add_argument("--no-ownship", action="store_true")
    p.add_argument("--seconds", type=int, default=0, help="stop after this many seconds (0 runs until stopped)")
    a = p.parse_args()
    if a.android:
        subprocess.run(["adb", "-s", a.serial, "emu", "redir", "add", f"udp:{a.port}:{a.port}"], check=False)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    start = time.time()
    while not a.seconds or time.time() - start < a.seconds:
        now = time.time()
        own, track, traffic = scene(now - start)
        messages = [heartbeat(now), device_id()]
        if not a.no_ownship:
            messages += [report(0x0A, 0xC0FFEE, own[0], own[1], OWN_ALT, track, 100, 0, "N1BS"), geo_altitude(OWN_ALT)]
        sock.sendto(b"".join(frame(m) for m in messages + traffic), (a.host, a.port))
        time.sleep(1)


if __name__ == "__main__":
    main()
