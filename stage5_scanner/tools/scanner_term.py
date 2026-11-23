"""
Stage 5 PC terminal: shows what the board prints and sends single-key commands.

  py -3 tools\\scanner_term.py --port COM23

Type a command letter and press Enter (e.g. b, s, +, -, r, g, o).
  b : learn background (tray EMPTY)     s : status
  + / - : threshold up / down           ] / [ : min blocks up / down
  g / r / y : box color                 o : auto (box only when object) / always
  q : quit
(For dataset capture keep using tools\\capture_to_png.py - close this terminal first.)
"""
import argparse
import sys
import threading
import time

import serial


def reader(ser, stop):
    while not stop.is_set():
        try:
            data = ser.read(256)
        except serial.SerialException:
            break
        if data:
            sys.stdout.write(data.decode("ascii", "replace"))
            sys.stdout.flush()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=460800)
    args = ap.parse_args()

    with serial.Serial(args.port, args.baud, timeout=0.1) as ser:
        stop = threading.Event()
        t = threading.Thread(target=reader, args=(ser, stop), daemon=True)
        t.start()
        print(f"connected {args.port} @ {args.baud}. type a command + Enter, q to quit")
        ser.write(b"s")
        try:
            for line in sys.stdin:
                cmd = line.strip()
                if cmd == "q":
                    break
                if cmd:
                    ser.write(cmd[0].encode("ascii"))
                    time.sleep(0.05)
        except KeyboardInterrupt:
            pass
        stop.set()
        t.join(timeout=1)


if __name__ == "__main__":
    sys.exit(main())
