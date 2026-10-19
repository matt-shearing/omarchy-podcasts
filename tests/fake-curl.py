#!/usr/bin/env python3
"""Offline stand-in for curl, so the suite tests our own code and not the
internet.

Serves files out of tests/fixtures/ keyed by URL, honours the conditional-GET
headers the real fetch sends, and can be told to fail, redirect or stall via a
routes file. Speaks exactly the curl surface podcasts.py uses: -o, -D, -w,
-H, --max-filesize, and curl's own exit codes.
"""

import fcntl
import json
import os
import sys
import time

FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
ROUTES = os.environ.get("FAKE_CURL_ROUTES", "")


def routes():
    if not ROUTES or not os.path.exists(ROUTES):
        return {}
    try:
        with open(ROUTES, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def main(argv):
    dest = ""
    header_dump = ""
    write_format = ""
    headers = {}
    url = ""
    max_filesize = 0
    resume = False

    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "-o":
            index += 1
            dest = argv[index]
        elif arg == "-D":
            index += 1
            header_dump = argv[index]
        elif arg == "-w":
            index += 1
            write_format = argv[index]
        elif arg == "-H":
            index += 1
            name, _, value = argv[index].partition(":")
            headers[name.strip().lower()] = value.strip()
        elif arg == "--max-filesize":
            index += 1
            max_filesize = int(argv[index])
        elif arg == "-C":
            index += 1
            resume = True
        elif arg in ("-A", "--max-time", "--connect-timeout", "--max-redirs",
                     "--retry", "--proto", "--proto-redir", "-X", "--data-binary",
                     "--speed-limit", "--speed-time"):
            index += 1
        elif arg in ("-sS", "-L"):
            pass
        elif not arg.startswith("-"):
            url = arg
        index += 1

    route = routes().get(url, {})
    if "audio" in route:
        return serve_audio(route, url, dest, header_dump, write_format,
                           headers, max_filesize, resume)
    status = int(route.get("status", 200))
    fixture = route.get("fixture", "")
    exit_code = int(route.get("exit", 0))
    location = route.get("location", "")
    etag = route.get("etag", "")
    modified = route.get("modified", "")

    if exit_code:
        sys.stderr.write("curl: (%d) simulated failure\n" % exit_code)
        return exit_code

    # Conditional GET: answer 304 when the caller echoes back what we gave it.
    if status == 200 and etag and headers.get("if-none-match") == etag:
        status = 304
    elif status == 200 and modified and headers.get("if-modified-since") == modified:
        status = 304

    body = b""
    if status == 200 and fixture:
        path = os.path.join(FIXTURES, fixture)
        try:
            with open(path, "rb") as handle:
                body = handle.read()
        except OSError:
            sys.stderr.write("curl: (22) missing fixture %s\n" % fixture)
            return 22

    if max_filesize and len(body) > max_filesize:
        sys.stderr.write("curl: (63) Maximum file size exceeded\n")
        return 63

    blocks = []
    final_url = url
    if location:
        blocks.append("HTTP/1.1 %d Moved\r\nLocation: %s\r\n" % (status, location))
        final_url = location
        redirected = routes().get(location, {})
        status = int(redirected.get("status", 200))
        etag = redirected.get("etag", "")
        modified = redirected.get("modified", "")
        if redirected.get("fixture"):
            try:
                with open(os.path.join(FIXTURES, redirected["fixture"]), "rb") as handle:
                    body = handle.read()
            except OSError:
                body = b""

    tail = "HTTP/1.1 %d OK\r\n" % status
    if etag:
        tail += "ETag: %s\r\n" % etag
    if modified:
        tail += "Last-Modified: %s\r\n" % modified
    tail += "Content-Type: application/xml\r\n"
    blocks.append(tail)

    if dest:
        with open(dest, "wb") as handle:
            handle.write(body if status == 200 else b"")
    if header_dump:
        with open(header_dump, "w", encoding="utf-8") as handle:
            handle.write("\r\n".join(blocks))

    if write_format:
        route_ip = route.get("remote_ip", "203.0.113.10")
        # curl reports whether this request actually went through a proxy,
        # which is not the same as one being configured (no_proxy).
        proxy_used = str(route.get("proxy_used", "0"))
        sys.stdout.write(write_format
                         .replace("%{http_code}", str(status))
                         .replace("%{remote_ip}", route_ip)
                         .replace("%{proxy_used}", proxy_used)
                         .replace("%{url_effective}", final_url))
    return 0


# ------------------------------------------------------ episode audio (fork)
#
# A route with "audio": N serves an N-byte episode body. Options:
#   content_type   the Content-Type to answer with (default audio/mpeg)
#   etag           validator; a resume whose If-Range differs gets a 200
#   ranges         honour -C (resume) with a 206 (default true)
#   cut_at         write this many bytes, then fail like a dropped link (18)
#   sleep          seconds to hold the transfer open
#   location       one redirect hop first, as the feed routes do
#   remote_ip      the address curl reports having connected to
# Every transfer is counted in $FAKE_CURL_ROUTES.active so the suite can see
# how many ran at once.

def audio_body(size, version=""):
    seed = (version or "v1").encode("utf-8")
    block = bytes((i * 7 + sum(seed)) % 251 for i in range(4096))
    return (block * (size // len(block) + 1))[:size]


def track_active(delta):
    path = ROUTES + ".active"
    with open(path, "a+") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        handle.seek(0)
        raw = handle.read().split()
        now = int(raw[0]) if raw else 0
        peak = int(raw[1]) if len(raw) > 1 else 0
        now += delta
        peak = max(peak, now)
        handle.seek(0)
        handle.truncate()
        handle.write("%d %d" % (now, peak))


def serve_audio(route, url, dest, header_dump, write_format, headers,
                max_filesize, resume):
    size = int(route["audio"])
    etag = route.get("etag", "")
    body = audio_body(size, etag)
    ctype = route.get("content_type", "audio/mpeg")
    blocks = []
    final_url = url
    if route.get("location"):
        blocks.append("HTTP/1.1 302 Found\r\nLocation: %s\r\n" % route["location"])
        final_url = route["location"]

    offset = 0
    if resume and dest and os.path.exists(dest):
        offset = os.path.getsize(dest)
    status = 200
    if offset:
        same = not etag or headers.get("if-range", "") == etag
        if route.get("ranges", True) and same:
            status = 206
        else:
            # The server sent the whole file; curl refuses to append it.
            sys.stderr.write("curl: (33) HTTP server doesn't seem to support byte ranges. Cannot resume.\n")
            return 33

    part = body[offset:]
    if max_filesize and len(part) > max_filesize:
        sys.stderr.write("curl: (63) Maximum file size exceeded\n")
        return 63

    tail = "HTTP/1.1 %d OK\r\nContent-Type: %s\r\nContent-Length: %d\r\n" % (
        status, ctype, len(part))
    if status == 206:
        tail += "Content-Range: bytes %d-%d/%d\r\n" % (offset, size - 1, size)
    if etag:
        tail += "ETag: %s\r\n" % etag
    blocks.append(tail)
    if header_dump:
        with open(header_dump, "w", encoding="utf-8") as handle:
            handle.write("\r\n".join(blocks) + "\r\n")

    track_active(1)
    try:
        if route.get("sleep"):
            time.sleep(float(route["sleep"]))
        cut = route.get("cut_at")
        chunk = part if cut is None else part[:max(0, int(cut) - offset)]
        if dest:
            with open(dest, "ab" if offset else "wb") as handle:
                handle.write(chunk)
    finally:
        track_active(-1)
    if cut is not None:
        sys.stderr.write("curl: (18) transfer closed with outstanding read data remaining\n")
        return 18

    if write_format:
        sys.stdout.write(write_format
                         .replace("%{http_code}", str(status))
                         .replace("%{remote_ip}", route.get("remote_ip", "203.0.113.10"))
                         .replace("%{proxy_used}", "0")
                         .replace("%{content_type}", ctype)
                         .replace("%{url_effective}", final_url))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
