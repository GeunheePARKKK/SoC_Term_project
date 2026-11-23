"""
Stage 3 PC tool: ask the board for camera frames over UART and save them as PNG.

Board side: stage3_capture/sdk_src/main.c
  'c' -> "FRAME <n> <w> <h>\\r\\n" + w*h*3 raw RGB bytes + "END\\r\\n"
  UART: 921600 bps 8N1

Examples
  py -3 tools\\capture_to_png.py --port COM23
        -> captures/frame_0000.png (128x128) + frame_0000_x4.png (512x512 preview)
  py -3 tools\\capture_to_png.py --port COM23 --label scissors -n 50 --interval 0.5
        -> captures/scissors/scissors_0000.png ... 50 frames
  py -3 tools\\capture_to_png.py --port COM23 --info
        -> print the IP status line and exit
"""
import argparse
import os
import sys
import time

import numpy as np
import serial
from PIL import Image


def read_line(ser, timeout_s):
    end = time.time() + timeout_s
    buf = b""
    while time.time() < end:
        ch = ser.read(1)
        if not ch:
            continue
        if ch == b"\n":
            return buf.decode("ascii", "replace").strip()
        buf += ch
    raise TimeoutError("no response from the board (is capture_app running? right COM port?)")


def read_exact(ser, n, timeout_s):
    end = time.time() + timeout_s
    data = bytearray()
    while len(data) < n:
        if time.time() > end:
            raise TimeoutError(f"frame data incomplete: {len(data)}/{n} bytes")
        chunk = ser.read(n - len(data))
        if chunk:
            data += chunk
    return bytes(data)


def grab(ser, timeout_s=10.0):
    ser.reset_input_buffer()
    ser.write(b"c")
    while True:
        line = read_line(ser, timeout_s)
        if line.startswith("ERR"):
            raise RuntimeError(line)
        if line.startswith("FRAME"):
            break
    parts = line.split()
    count, w, h = int(parts[1]), int(parts[2]), int(parts[3])
    raw = read_exact(ser, w * h * 3, timeout_s)
    tail = read_line(ser, timeout_s)
    if tail != "END":
        raise ValueError(f"expected END, got {tail!r}")
    img = np.frombuffer(raw, dtype=np.uint8).reshape(h, w, 3)
    return count, img


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", required=True, help="UART COM port, e.g. COM23")
    ap.add_argument("--baud", type=int, default=921600)
    ap.add_argument("--out", default="captures", help="output folder")
    ap.add_argument("--label", default="", help="class name -> subfolder (e.g. scissors)")
    ap.add_argument("-n", "--count", type=int, default=1, help="number of frames")
    ap.add_argument("--interval", type=float, default=0.0, help="seconds between frames")
    ap.add_argument("--info", action="store_true", help="print IP status and exit")
    args = ap.parse_args()

    with serial.Serial(args.port, args.baud, timeout=0.2) as ser:
        if args.info:
            ser.reset_input_buffer()
            ser.write(b"i")
            print(read_line(ser, 3.0))
            return 0

        out_dir = os.path.join(args.out, args.label) if args.label else args.out
        os.makedirs(out_dir, exist_ok=True)
        prefix = args.label or "frame"
        start_idx = len([f for f in os.listdir(out_dir) if f.endswith(".png") and "_x" not in f])

        for k in range(args.count):
            t0 = time.time()
            n, img = grab(ser)
            name = f"{prefix}_{start_idx + k:04d}"
            h, w = img.shape[:2]
            Image.fromarray(img).save(os.path.join(out_dir, name + ".png"))
            Image.fromarray(img).resize((w * 4, h * 4), Image.NEAREST).save(os.path.join(out_dir, name + "_x4.png"))
            mean = img.reshape(-1, 3).mean(axis=0)
            print(f"[{k+1}/{args.count}] {name}.png {w}x{h}  ({time.time()-t0:.2f}s, capture #{n})  "
                  f"mean RGB = {mean[0]:.0f} {mean[1]:.0f} {mean[2]:.0f}")
            if args.interval > 0 and k + 1 < args.count:
                time.sleep(args.interval)
        print(f"saved to {os.path.abspath(out_dir)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
