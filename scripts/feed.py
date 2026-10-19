"""The Feed view (fork addition): every episode from every show published in
the last N days, newest first, whatever its triage state.

Upstream's inbox shows only what is still waiting on a decision; this is the
plain timeline beside it. Read-only — it takes no lock and writes nothing.
"""

import time

pc = None   # the host podcasts.py module, bound before any call

DEFAULT_DAYS = 14
MAX_DAYS = 365
MAX_ROWS = 400


def bind(host):
    global pc
    pc = host


def cmd_feed(args):
    days = int(pc.clamp_number(args.days, 1, MAX_DAYS, DEFAULT_DAYS))
    limit = int(pc.clamp_number(args.limit, 1, MAX_ROWS, MAX_ROWS))
    since = int(time.time()) - days * 86400
    shows = pc.load_shows()
    lib = pc.load_library()
    queued = set(lib["queue"])
    rows = []
    for show in shows:
        for episode in pc.hydrate(pc.load_episodes(show["id"]), show, lib):
            if episode["pub"] < since:
                continue
            episode["queued"] = episode["id"] in queued
            rows.append(episode)
    rows.sort(key=lambda e: -e["pub"])
    pc.emit({"ok": True, "days": days, "total": len(rows),
             "episodes": rows[:limit]})


def register(sub):
    p = sub.add_parser("feed")
    p.add_argument("--days", default=DEFAULT_DAYS)
    p.add_argument("--limit", default=MAX_ROWS)
    p.set_defaults(run=cmd_feed)
