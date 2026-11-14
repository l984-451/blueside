#!/usr/bin/env python3
"""Serves a folder with Range and ETag so an interrupted download can resume.

usage: range_server.py <port> <folder> [--rate MB_PER_S] [--log FILE]
/slow/<path> is throttled, /once/<path> is damaged on its first request,
/drop/<path> closes the connection a quarter of the way through its first request,
/sha256/<path> answers with the file's hash, /ranges/<path> with the number of
ranged requests seen for that path and query.
"""
import argparse
import hashlib
import http.server
import os
import time

parser = argparse.ArgumentParser()
parser.add_argument("port", type=int)
parser.add_argument("folder")
parser.add_argument("--rate", type=float, default=2.0)
parser.add_argument("--log", default=os.devnull)
args = parser.parse_args()
root = os.path.realpath(args.folder)
damaged = set()
dropped = set()
ranged = {}


def log(text):
    with open(args.log, "a") as f:
        f.write("%.3f %s\n" % (time.time(), text))


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_GET(self):
        mode, name = "", self.path.split("?")[0].lstrip("/")
        for prefix in ("slow", "once", "drop", "sha256", "ranges"):
            if name.startswith(prefix + "/"):
                mode, name = prefix, name[len(prefix) + 1:]
        key = name + "?" + self.path.partition("?")[2]
        path = os.path.realpath(os.path.join(root, name))
        if not path.startswith(root + os.sep) or not os.path.isfile(path):
            log("404 %s" % self.path)
            self.send_error(404)
            return
        if mode in ("sha256", "ranges"):
            digest = hashlib.sha256()
            with open(path, "rb") as f:
                while mode == "sha256" and (chunk := f.read(1 << 20)):
                    digest.update(chunk)
            body = (digest.hexdigest() if mode == "sha256" else str(ranged.get(key, 0))).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        size = os.path.getsize(path)
        rng = self.headers.get("Range")
        start = int(rng.split("=")[1].split("-")[0]) if rng else 0
        if rng:
            ranged[key] = ranged.get(key, 0) + 1
        log("GET %s Range=%s If-Range=%s" % (self.path, rng, self.headers.get("If-Range")))
        self.send_response(206 if rng else 200)
        self.send_header("Content-Length", str(size - start))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", '"%d-%d"' % (size, int(os.path.getmtime(path))))
        self.send_header("Last-Modified", self.date_time_string(os.path.getmtime(path)))
        if rng:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, size - 1, size))
        self.end_headers()
        damage = mode == "once" and self.path not in damaged
        damaged.add(self.path)
        # The first request for a drop path stops a quarter of the way in, with the connection closed.
        stop = start + (size - start) // 4 if mode == "drop" and self.path not in dropped else size
        dropped.add(self.path)
        step = max(int(args.rate * 1e6 / 10), 1) if mode == "slow" else 1 << 20
        sent = start
        try:
            with open(path, "rb") as f:
                f.seek(start)
                while chunk := f.read(step):
                    if damage:
                        chunk, damage = bytes([chunk[0] ^ 0xFF]) + chunk[1:], False
                    self.wfile.write(chunk)
                    sent += len(chunk)
                    if sent >= stop and stop < size:
                        log("dropped %s at %d" % (self.path, sent))
                        self.close_connection = True
                        return
                    if mode == "slow":
                        time.sleep(0.1)
            log("done %s %d" % (self.path, sent))
        except OSError as error:
            log("client gone %s at %d: %s" % (self.path, sent, error))


http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
