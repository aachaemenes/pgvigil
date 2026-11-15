#!/usr/bin/env python3
"""A PostgreSQL wire proxy for scripts/proof-agent.sh: it forwards every connection to the target and acts on the
statement text of a Parse message, so a proof can break a connection at a chosen point of a chosen call.

    proof-pgproxy.py --listen PORT --target HOST:PORT --rules FILE --log FILE

FILE holds lines '<action> <text>', read again at every Parse; each line fires once:
    drop  <text>   on the connection whose Parse carried <text>, the next Execute is sent and the server's answer held
                   until its ReadyForQuery (the statement and its implicit transaction have ended: a write committed);
                   then both sides are closed, so the client never reads the answer
    stall <text>   the Parse and everything after it on that connection are held: the server never sees the
                   statement and the client never gets an answer, until the client closes
The log gets 'seen <text>' for every Parse that carries a line's text and 'fired <action> <text>' when a line fires.
Test only: no TLS (the proof's connections use sslmode=disable).
"""
import argparse
import socket
import struct
import threading

READY = b"Z\x00\x00\x00\x05"  # ReadyForQuery: 'Z', length 5, then the transaction status byte


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", type=int, required=True)
    ap.add_argument("--target", required=True)
    ap.add_argument("--rules", required=True)
    ap.add_argument("--log", required=True)
    a = ap.parse_args()
    host, port = a.target.rsplit(":", 1)
    fired = set()
    lock = threading.Lock()

    def log(line):
        with lock:
            with open(a.log, "a") as f:
                f.write(line + "\n")

    def rules():
        out = []
        try:
            with open(a.rules) as f:
                for line in f:
                    p = line.rstrip("\n").split(" ", 1)
                    if len(p) == 2 and p[0] in ("drop", "stall") and p[1]:
                        out.append((p[0], p[1]))
        except OSError:
            pass
        return out

    def serve(c):
        try:
            s = socket.create_connection((host, int(port)), timeout=10)
            s.settimeout(None)
        except OSError:
            c.close()
            return
        st = {"mode": None}  # None | 'armed' (a drop waits for its Execute) | 'dropping' | 'stall'

        def close():
            for x in (c, s):
                try:
                    x.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                try:
                    x.close()
                except OSError:
                    pass

        def down():  # the server's bytes to the client
            held = b""
            while True:
                try:
                    d = s.recv(65536)
                except OSError:
                    break
                if not d:
                    break
                if st["mode"] == "dropping":
                    held += d
                    if READY in held:
                        break
                    continue
                if st["mode"] == "stall":
                    continue
                try:
                    c.sendall(d)
                except OSError:
                    break
            close()

        threading.Thread(target=down, daemon=True).start()
        buf, started = b"", False
        while True:
            try:
                d = c.recv(65536)
            except OSError:
                break
            if not d:
                break
            if st["mode"] == "stall":
                continue
            buf += d
            out = b""
            while True:
                if not started:  # the startup packet (or an SSL / GSS / cancel request): no type byte
                    if len(buf) < 8:
                        break
                    n = struct.unpack("!I", buf[:4])[0]
                    if len(buf) < n:
                        break
                    msg, buf = buf[:n], buf[n:]
                    if struct.unpack("!I", msg[4:8])[0] >> 16 == 3:
                        started = True
                    out += msg
                    continue
                if len(buf) < 5:
                    break
                n = struct.unpack("!I", buf[1:5])[0]
                if len(buf) < 1 + n:
                    break
                msg, buf = buf[:1 + n], buf[1 + n:]
                kind = msg[:1]
                if kind == b"P":
                    text = msg[5:].decode("utf-8", "replace")
                    for act, want in rules():
                        if want not in text:
                            continue
                        log("seen " + want)
                        key = act + " " + want
                        with lock:
                            if key in fired:
                                continue
                            fired.add(key)
                        log("fired " + key)
                        st["mode"] = "stall" if act == "stall" else "armed"
                if st["mode"] == "stall":
                    buf = b""
                    break
                if kind == b"E" and st["mode"] == "armed":
                    st["mode"] = "dropping"  # set before the Execute is sent: every answer after it is held
                out += msg
            if out:
                try:
                    s.sendall(out)
                except OSError:
                    break
        close()

    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", a.listen))
    srv.listen(64)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=serve, args=(c,), daemon=True).start()


if __name__ == "__main__":
    main()
