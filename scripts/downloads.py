"""Offline episode downloads for the bottelet.podcasts helper.

This is a fork addition, kept in its own file so upstream's podcasts.py can
keep moving underneath it. podcasts.py calls in at exactly two places: its
argument parser registers the `download-*` subcommands from here, and a feed
refresh hands its new episode ids to `note_new` for auto-download. Everything
else — state, files, the worker — lives in this module.

State is a new file, `downloads.json`, beside upstream's own. It is never
folded into library.json: load_library() rebuilds that file from a fixed set
of keys, so anything extra written there is dropped on the next save.

    downloads.json
      items  epId -> {show, state, file, bytes, total, error, added, done,
                      playedSeen, resumeFailed}
      shows  showId -> {auto: bool}       absent = follow the show's mode

    downloads/<showId>/<epId>.<ext>       finished audio
    downloads/<showId>/<epId>.part        in progress (resumable)
    downloads/<showId>/<epId>.hdr         curl's header dump for that transfer

The same rules as the rest of the helper apply: one JSON object out, exit 0,
curl as an argv list, HTTPS only, every URL a feed controls checked against
loopback and link-local, caps and timeouts on everything, no retry storms.
"""

import errno
import fcntl
import os
import subprocess
import time

pc = None   # the host podcasts.py module, bound before any call


def bind(host):
    global pc
    pc = host


# ------------------------------------------------------------------ bounds

DEFAULT_MAX_MB = 1024           # episode audio cap; video episodes run large
DEFAULT_PARALLEL = 2
DEFAULT_CLEANUP_DAYS = 7
MAX_PARALLEL = 6
DOWNLOAD_MAX_TIME = 3 * 3600    # a whole transfer, however slow
CONNECT_TIMEOUT = 15
# A transfer that moves under 1 KB/s for a minute has stalled; curl gives up
# instead of holding a slot for the full max-time.
STALL_BYTES = 1024
STALL_SECONDS = 60
# Podcast enclosures routinely pass through several tracking prefixes
# (Podtrac, Chartable, OP3, Podsights) before the CDN. Feeds get five hops;
# audio needs more.
MAX_REDIRECTS = 10
POLL_SECONDS = 0.5
MAX_ITEMS = 5000
STATE_LOCK_TIMEOUT = 30

# Loose on purpose: hosts label audio every way imaginable. What this refuses
# is the case that matters — an HTML error page or a JSON blob saved as an
# "episode".
ACCEPT_TYPES = ("application/octet-stream", "binary/octet-stream",
                "application/ogg", "application/mp4", "application/x-mpeg",
                "application/mpeg", "application/download",
                "application/force-download", "application/x-download")
EXTENSIONS = {
    "audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/x-mpeg": "mp3",
    "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/m4a": "m4a",
    "audio/aac": "aac", "audio/x-aac": "aac",
    "audio/ogg": "ogg", "application/ogg": "ogg", "audio/opus": "opus",
    "audio/wav": "wav", "audio/x-wav": "wav", "audio/flac": "flac",
    "audio/webm": "webm", "video/webm": "webm",
    "video/mp4": "mp4", "video/x-m4v": "m4v", "video/quicktime": "mov",
}
KNOWN_EXTENSIONS = set(EXTENSIONS.values())
STATES = ("queued", "downloading", "done", "failed")


def root():
    return os.path.join(pc.ROOT, "downloads")


def state_file():
    return os.path.join(pc.ROOT, "downloads.json")


def show_dir(show_id):
    return os.path.join(root(), show_id)


def part_path(show_id, episode_id):
    return os.path.join(show_dir(show_id), episode_id + ".part")


def hdr_path(show_id, episode_id):
    return os.path.join(show_dir(show_id), episode_id + ".hdr")


def ensure_root():
    """Same discipline as ensure_dirs(): a link where a directory should be
    sends every write somewhere else, so it is refused, not followed."""
    for path in (root(),):
        if os.path.islink(path):
            pc.fail("%s is a symbolic link; refusing to write through it" % path)
        try:
            os.makedirs(path, mode=0o700, exist_ok=True)
        except OSError as exc:
            pc.fail("cannot create %s: %s" % (path, exc.strerror))


def ensure_show_dir(show_id):
    if not pc.ID_RE.match(show_id):
        pc.fail("bad show id")
    ensure_root()
    path = show_dir(show_id)
    if os.path.islink(path):
        pc.fail("%s is a symbolic link; refusing to write through it" % path)
    try:
        os.makedirs(path, mode=0o700, exist_ok=True)
    except OSError as exc:
        pc.fail("cannot create %s: %s" % (path, exc.strerror))
    return path


# ------------------------------------------------------------------- state

class StateLock(object):
    """Guards downloads.json only. Deliberately not upstream's lock: a feed
    refresh or an OPML import holds that one for minutes, and the worker must
    be able to record progress in the meantime. The worker never takes
    upstream's lock, so the order is always upstream → ours."""

    def __init__(self, name=".downloads.lock", timeout=STATE_LOCK_TIMEOUT):
        self.path = os.path.join(pc.ROOT, name)
        self.timeout = timeout
        self.handle = None

    def __enter__(self):
        self.handle = open(self.path, "a+")
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except OSError as exc:
                if exc.errno not in (errno.EAGAIN, errno.EACCES):
                    self.handle.close()
                    pc.fail("cannot lock download state: %s" % exc.strerror)
                if time.monotonic() >= deadline:
                    self.handle.close()
                    pc.fail("download state is busy — try again shortly")
                time.sleep(0.05)

    def __exit__(self, *_exc):
        try:
            fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
        finally:
            self.handle.close()


def try_worker_lock():
    """Held for the worker's whole life, so two shells (or two clicks) can
    never run two workers and double the parallel-download limit."""
    handle = open(os.path.join(pc.ROOT, ".download-worker.lock"), "a+")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        return None
    return handle


def worker_running():
    handle = try_worker_lock()
    if handle is None:
        return True
    handle.close()
    return False


def load_state():
    data = pc.read_state(state_file(), "your downloads file")
    if data is None:
        data = {}
    if not isinstance(data, dict):
        pc.fail("your downloads file is not in the expected format; leaving "
                "it alone rather than overwriting it")
    items = data.get("items") if isinstance(data.get("items"), dict) else {}
    shows = data.get("shows") if isinstance(data.get("shows"), dict) else {}
    if len(items) > MAX_ITEMS:
        pc.fail("downloads.json lists %d downloads, more than the %d this "
                "plugin will handle; it has been left untouched"
                % (len(items), MAX_ITEMS))
    out_items = {}
    for key, rec in items.items():
        if not (isinstance(key, str) and pc.ID_RE.match(key)
                and isinstance(rec, dict)):
            continue
        show = rec.get("show")
        if not (isinstance(show, str) and pc.ID_RE.match(show)):
            continue
        state = rec.get("state") if rec.get("state") in STATES else "failed"
        name = rec.get("file") if isinstance(rec.get("file"), str) else ""
        # The file name is ours, but the record is in a user-writable file:
        # it has to be exactly <epId>.<known ext> or nothing.
        if name and not (name.startswith(key + ".")
                         and name[len(key) + 1:] in KNOWN_EXTENSIONS):
            name = ""
        out_items[key] = {
            "show": show,
            "state": state,
            "file": name,
            "bytes": int(pc.clamp_number(rec.get("bytes"), 0, 1e13, 0)),
            "total": int(pc.clamp_number(rec.get("total"), 0, 1e13, 0)),
            "error": str(rec.get("error") or "")[:200],
            "added": int(pc.clamp_number(rec.get("added"), 0, 4e12, 0)),
            "done": int(pc.clamp_number(rec.get("done"), 0, 4e12, 0)),
            "playedSeen": int(pc.clamp_number(rec.get("playedSeen"), 0, 4e12, 0)),
            "resumeFailed": bool(rec.get("resumeFailed")),
            "validator": validator_of(rec.get("validator")),
        }
    out_shows = {}
    for key, rec in shows.items():
        if (isinstance(key, str) and pc.ID_RE.match(key) and isinstance(rec, dict)
                and isinstance(rec.get("auto"), bool)):
            out_shows[key] = {"auto": rec["auto"]}
    return {"version": 1, "items": out_items, "shows": out_shows}


def validator_of(value):
    """An ETag or Last-Modified echoed back as If-Range. It came from a
    server, so CR/LF (header injection) and anything oversized are refused."""
    text = str(value or "")
    if len(text) > 200 or "\r" in text or "\n" in text:
        return ""
    return text


def save_state(state):
    pc.save_json(state_file(), state)


def final_path(show_id, rec):
    return os.path.join(show_dir(show_id), rec["file"]) if rec.get("file") else ""


# ------------------------------------------------------------- library view

def episode_index(shows):
    """epId -> (show, episode) across every subscription."""
    index = {}
    for show in shows:
        for episode in pc.load_episodes(show["id"]):
            index[episode["id"]] = (show, episode)
    return index


def auto_enabled(state, show):
    pref = state["shows"].get(show["id"])
    if pref is not None:
        return pref["auto"]
    return show.get("mode") == "auto"


def download_url(show, episode):
    """The enclosure, held to HTTPS. A feed may publish http:// enclosures —
    upstream lets mpv stream those — but a download is a much larger thing to
    fetch in the clear, so it is upgraded to https:// unless the user has
    already made this show an explicit HTTP exception."""
    url = str(episode.get("url") or "")
    allow_http = bool(show.get("allowHttp"))
    if url.lower().startswith("http://") and not allow_http:
        url = "https://" + url[len("http://"):]
    return pc.valid_url(url, allow_http), allow_http


def disk_usage():
    total = 0
    try:
        for show_id in os.listdir(root()):
            directory = show_dir(show_id)
            if os.path.islink(directory) or not os.path.isdir(directory):
                continue
            for name in os.listdir(directory):
                try:
                    st = os.lstat(os.path.join(directory, name))
                except OSError:
                    continue
                total += st.st_size
    except OSError:
        pass
    return total


def size_of(path):
    try:
        return os.lstat(path).st_size
    except OSError:
        return 0


def public_item(episode_id, rec):
    out = {"state": rec["state"], "error": rec["error"],
           "bytes": rec["bytes"], "total": rec["total"]}
    if rec["state"] == "downloading" or rec["state"] == "queued":
        out["bytes"] = size_of(part_path(rec["show"], episode_id))
    if rec["state"] == "done":
        path = final_path(rec["show"], rec)
        if path and os.path.isfile(path) and not os.path.islink(path):
            out["path"] = path
        else:
            # Deleted behind our back. Report it honestly; the worker's next
            # pass drops the record.
            out["state"] = "missing"
    out["progress"] = (min(1.0, out["bytes"] / float(out["total"]))
                       if out["total"] > 0 else 0)
    return out


# ------------------------------------------------------------- refresh hook

def note_new(show, new_ids):
    """Called from cmd_refresh, inside upstream's lock, with the ids a poll
    just discovered. Queues the ones published after the subscription for
    download when the show has auto-download on. Never re-queues a failure:
    an episode that would not download stays failed until you ask again."""
    if not new_ids:
        return
    ensure_root()
    with StateLock():
        state = load_state()
        if not auto_enabled(state, show):
            return
        episodes = {e["id"]: e for e in pc.load_episodes(show["id"])}
        baseline = show.get("baseline", 0)
        changed = False
        for episode_id in new_ids:
            episode = episodes.get(episode_id)
            if not episode or episode["pub"] <= baseline:
                continue
            if episode_id in state["items"]:
                continue
            state["items"][episode_id] = new_record(show["id"], episode)
            changed = True
        if changed:
            save_state(state)


def new_record(show_id, episode):
    return {"show": show_id, "state": "queued", "file": "", "bytes": 0,
            "total": int(episode.get("bytes") or 0), "error": "",
            "added": int(time.time()), "done": 0, "playedSeen": 0,
            "resumeFailed": False, "validator": ""}


# ---------------------------------------------------------------- commands

def cmd_status(_args):
    ensure_root()
    state = load_state()
    emit_status(state)


def emit_status(state, **extra):
    items = {eid: public_item(eid, rec) for eid, rec in state["items"].items()}
    pending = sum(1 for rec in state["items"].values()
                  if rec["state"] in ("queued", "downloading"))
    out = {"ok": True, "items": items, "shows": state["shows"],
           "usedBytes": disk_usage(), "pending": pending,
           "worker": worker_running()}
    out.update(extra)
    pc.emit(out)


def cmd_add(args):
    episode_id = args.episode_id
    if not pc.ID_RE.match(episode_id):
        pc.fail("bad episode id")
    shows = pc.load_shows()
    found = episode_index(shows).get(episode_id)
    if not found:
        pc.fail("that episode is no longer in its feed")
    show, episode = found
    url, _allow = download_url(show, episode)
    if not url:
        pc.fail("that episode has no HTTPS address to download from")
    ensure_show_dir(show["id"])
    with StateLock():
        state = load_state()
        rec = state["items"].get(episode_id)
        if rec and rec["state"] in ("queued", "downloading"):
            emit_status(state)
        if rec and rec["state"] == "done" and os.path.isfile(final_path(rec["show"], rec)):
            emit_status(state)
        fresh = new_record(show["id"], episode)
        if rec:
            # A retry keeps whatever partial data the last attempt left.
            fresh["resumeFailed"] = rec.get("resumeFailed", False)
            fresh["validator"] = rec.get("validator", "")
        state["items"][episode_id] = fresh
        save_state(state)
        emit_status(state)


def delete_files(show_id, episode_id, rec=None):
    paths = [part_path(show_id, episode_id), hdr_path(show_id, episode_id)]
    if rec and rec.get("file"):
        paths.append(final_path(show_id, rec))
    for path in paths:
        if path and not os.path.isdir(path):
            pc.cleanup(path)


def cmd_remove(args):
    episode_id = args.episode_id
    if not pc.ID_RE.match(episode_id):
        pc.fail("bad episode id")
    ensure_root()
    with StateLock():
        state = load_state()
        rec = state["items"].pop(episode_id, None)
        if rec:
            # If the worker has this one in flight it notices the record has
            # gone on its next poll, kills curl and removes the partial.
            delete_files(rec["show"], episode_id, rec)
        save_state(state)
        emit_status(state)


def cmd_clear(_args):
    ensure_root()
    with StateLock():
        state = load_state()
        count = 0
        for episode_id, rec in list(state["items"].items()):
            delete_files(rec["show"], episode_id, rec)
            count += 1
        state["items"] = {}
        save_state(state)
        sweep_orphans(state)
        emit_status(state, cleared=count)


def cmd_show(args):
    show_id, value = args.show_id, args.value
    if not pc.ID_RE.match(show_id):
        pc.fail("bad show id")
    ensure_root()
    with StateLock():
        state = load_state()
        if value == "default":
            state["shows"].pop(show_id, None)
        else:
            state["shows"][show_id] = {"auto": value == "on"}
        save_state(state)
        emit_status(state)


# ------------------------------------------------------------------ worker

def sweep_orphans(state):
    """Files in the downloads tree that no record claims: a partial from a
    download you since deleted, a finished file whose record was lost. A
    `.part` that a queued record still wants is kept — that is the resume."""
    try:
        show_ids = os.listdir(root())
    except OSError:
        return
    wanted = {}
    for episode_id, rec in state["items"].items():
        names = wanted.setdefault(rec["show"], set())
        if rec["state"] in ("queued", "downloading", "failed"):
            names.add(episode_id + ".part")
        if rec["state"] == "done" and rec["file"]:
            names.add(rec["file"])
    for show_id in show_ids:
        directory = show_dir(show_id)
        if not pc.ID_RE.match(show_id) or os.path.islink(directory) \
                or not os.path.isdir(directory):
            continue
        keep = wanted.get(show_id, set())
        try:
            names = os.listdir(directory)
        except OSError:
            continue
        for name in names:
            if name in keep:
                continue
            path = os.path.join(directory, name)
            if os.path.isfile(path) or os.path.islink(path):
                pc.cleanup(path)
        try:
            os.rmdir(directory)     # only succeeds once it is empty
        except OSError:
            pass


def startup_pass(cleanup_days):
    """Run once per worker before anything downloads: recover what a killed
    shell left mid-transfer, drop what no longer belongs, and apply the
    played-episode retention rule."""
    shows = pc.load_shows()
    lib = pc.load_library()
    live = episode_index(shows)
    subscribed = {show["id"] for show in shows}
    now = int(time.time())
    deleted = 0
    with StateLock():
        state = load_state()
        for episode_id, rec in list(state["items"].items()):
            if rec["state"] == "downloading":
                # Nobody is downloading it: we hold the worker lock. The
                # partial is still there, so it resumes.
                rec["state"] = "queued"
            gone = episode_id not in live and episode_id != lib["now"]
            # Same belt as prune_triage: an empty subscription list is more
            # likely a read gone wrong than an unsubscribe from everything.
            if subscribed and (rec["show"] not in subscribed or gone):
                delete_files(rec["show"], episode_id, rec)
                del state["items"][episode_id]
                deleted += 1
                continue
            if rec["state"] == "done":
                path = final_path(rec["show"], rec)
                if not path or not os.path.isfile(path):
                    del state["items"][episode_id]
                    continue
                if lib["triage"].get(episode_id) == "played" and episode_id != lib["now"]:
                    # When it was marked played, if the library recorded it;
                    # otherwise the first time this pass saw it played.
                    played_at = int(lib["positions"].get(episode_id, {}).get("ts", 0)
                                    or rec["playedSeen"] or now)
                    rec["playedSeen"] = rec["playedSeen"] or played_at
                    if cleanup_days > 0 and now - played_at >= cleanup_days * 86400:
                        delete_files(rec["show"], episode_id, rec)
                        del state["items"][episode_id]
                        deleted += 1
        save_state(state)
        sweep_orphans(state)
    return deleted


def content_type_ok(value):
    kind = str(value or "").split(";", 1)[0].strip().lower()
    if not kind:
        return True
    return (kind.startswith("audio/") or kind.startswith("video/")
            or kind in ACCEPT_TYPES)


def extension_for(content_type, url, episode):
    for candidate in (content_type, episode.get("mime", "")):
        kind = str(candidate or "").split(";", 1)[0].strip().lower()
        if kind in EXTENSIONS:
            return EXTENSIONS[kind]
    path = pc.urlsplit(str(url)).path.lower()
    tail = path.rsplit(".", 1)[-1] if "." in path.rsplit("/", 1)[-1] else ""
    if tail in KNOWN_EXTENSIONS:
        return tail
    return "mp3"


def final_block(path):
    """The last header block curl has written so far, or None while the
    transfer is still on a redirect hop."""
    blocks, _permanent = pc.parse_header_dump(path)
    if not blocks:
        return None, blocks
    last = blocks[-1]
    if 300 <= last["status"] < 400:
        return None, blocks
    return last, blocks


def total_from(block, offset):
    headers = block["headers"] if block else {}
    rng = headers.get("content-range", "")
    if "/" in rng:
        tail = rng.rsplit("/", 1)[1].strip()
        if tail.isdigit():
            return int(tail)
    length = headers.get("content-length", "")
    if length.isdigit():
        return int(length) + (offset if block and block["status"] == 206 else 0)
    return 0


class Transfer(object):
    def __init__(self, episode_id, show, episode, url, allow_http, max_bytes,
                 validator=""):
        self.id = episode_id
        self.show = show
        self.episode = episode
        self.url = url
        self.allow_http = allow_http
        self.max_bytes = max_bytes
        self.part = part_path(show["id"], episode_id)
        self.hdr = hdr_path(show["id"], episode_id)
        self.proc = None
        self.offset = 0
        self.killed = ""            # why we stopped it, if we did
        self.validator = validator

    def start(self, resume):
        ensure_show_dir(self.show["id"])
        pc.cleanup(self.hdr)
        # Resuming is only safe against the same file. Hosts that stitch ads
        # in per request serve a different file every time, and appending one
        # to the start of another makes a corrupt episode that plays fine
        # until the seam. If-Range makes the server send the whole thing
        # again when it has changed; with nothing to compare, start over.
        if not resume or not self.validator:
            pc.cleanup(self.part)
        if os.path.islink(self.part):
            pc.cleanup(self.part)
        self.offset = size_of(self.part)
        protos = "http,https" if self.allow_http else "https"
        argv = [
            "curl", "-sS",
            "--proto", "=" + protos,
            "--proto-redir", "=" + protos,
            "-L", "--max-redirs", str(MAX_REDIRECTS),
            "--max-filesize", str(self.max_bytes),
            "--max-time", str(DOWNLOAD_MAX_TIME),
            "--connect-timeout", str(CONNECT_TIMEOUT),
            "--speed-limit", str(STALL_BYTES),
            "--speed-time", str(STALL_SECONDS),
            "--retry", "0",
            "-A", pc.USER_AGENT,
            "-D", self.hdr,
            "-o", self.part,
            # content_type last: "audio/mpeg; charset=…" holds a space.
            "-w", "%{http_code} %{remote_ip} %{proxy_used} %{url_effective} %{content_type}",
        ]
        if self.offset > 0:
            argv += ["-C", "-", "-H", "If-Range: " + self.validator]
        argv.append(self.url)
        try:
            self.proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL,
                                         stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE)
        except OSError as exc:
            self.proc = None
            return "curl unavailable: %s" % exc.strerror
        return ""

    def kill(self, reason):
        self.killed = reason
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()

    def watch(self):
        """Mid-transfer checks, so a bad answer is stopped at its headers
        rather than after a gigabyte. Returns the total once it is known."""
        block, _blocks = final_block(self.hdr)
        if block is None:
            return 0
        status = block["status"]
        if status and not (200 <= status < 300) and status != 416:
            self.kill("HTTP %d" % status)
            return 0
        if not content_type_ok(block["headers"].get("content-type")):
            self.kill("that address does not serve audio (%s)"
                      % block["headers"].get("content-type", "")[:60])
            return 0
        if size_of(self.part) > self.max_bytes:
            self.kill("episode larger than %d MB" % (self.max_bytes // (1024 * 1024)))
            return 0
        if not self.validator and status in (200, 206):
            self.validator = validator_of(block["headers"].get("etag")
                                          or block["headers"].get("last-modified"))
        total = total_from(block, self.offset)
        if total > self.max_bytes:
            self.kill("episode larger than %d MB" % (self.max_bytes // (1024 * 1024)))
            return 0
        return total

    def finish(self):
        """Judge a transfer that has ended. Returns (outcome, detail) where
        outcome is one of done / retry-fresh / failed / cancelled."""
        out, err = self.proc.communicate()
        code = self.proc.returncode
        fields = out.decode("utf-8", "replace").strip().split(" ", 4)
        status = int(fields[0]) if fields and fields[0].isdigit() else 0
        remote_ip = fields[1] if len(fields) > 1 else ""
        proxy_used = fields[2] if len(fields) > 2 else ""
        final_url = fields[3] if len(fields) > 3 else self.url
        content_type = fields[4] if len(fields) > 4 else ""

        if self.killed == "cancelled":
            return "cancelled", ""
        if self.killed:
            self.discard()
            return "failed", self.killed

        # The server will not resume: curl 33, or a 416 for a range past what
        # it holds. Start once from zero; a second refusal is a failure.
        if self.offset > 0 and (code == 33 or status == 416):
            return "retry-fresh", "server cannot resume"
        if status == 200 and self.offset > 0 and code == 0:
            # A server that ignored the Range header and sent the whole file
            # from byte zero would have been appended after our partial.
            # curl refuses that case itself (33), but do not rely on it.
            return "retry-fresh", "server ignored the resume"

        if code != 0:
            message = pc.CURL_ERRORS.get(code)
            if message is None:
                lines = err.decode("utf-8", "replace").strip().splitlines()
                message = lines[-1][:200] if lines else "transfer failed (curl %d)" % code
            if code == 63:
                self.discard()
                return "failed", "episode larger than %d MB" % (self.max_bytes // (1024 * 1024))
            if code == 28:
                message = "the download stalled or took too long"
            if code == 1:
                message = "the episode moved to an address that is not HTTPS"
                self.discard()
            # Network trouble keeps the partial so a retry resumes.
            return "failed", message

        blocks, _permanent = pc.parse_header_dump(self.hdr)
        hops = [block["headers"].get("location", "") for block in blocks]
        hops.append(final_url)
        landed_badly = (False if pc.went_through_proxy(proxy_used)
                        else pc.connected_blocked(remote_ip))
        if landed_badly or any(hop and pc.hop_blocked(hop) for hop in hops):
            self.discard()
            return "failed", "that episode leads somewhere a podcast may not reach"
        if not (200 <= status < 300):
            self.discard()
            return "failed", "HTTP %d" % status
        if not content_type_ok(content_type):
            self.discard()
            return "failed", "that address does not serve audio"
        size = size_of(self.part)
        if size <= 0:
            self.discard()
            return "failed", "the server sent nothing"
        if size > self.max_bytes:
            self.discard()
            return "failed", "episode larger than %d MB" % (self.max_bytes // (1024 * 1024))

        name = "%s.%s" % (self.id, extension_for(content_type, final_url, self.episode))
        target = os.path.join(show_dir(self.show["id"]), name)
        try:
            os.replace(self.part, target)
        except OSError as exc:
            return "failed", "cannot save the episode: %s" % exc.strerror
        pc.cleanup(self.hdr)
        return "done", {"file": name, "bytes": size}

    def discard(self):
        pc.cleanup(self.part, self.hdr)


def cmd_run(args):
    parallel = int(pc.clamp_number(args.parallel, 1, MAX_PARALLEL, DEFAULT_PARALLEL))
    max_mb = int(pc.clamp_number(args.max_mb, 50, 16384, DEFAULT_MAX_MB))
    cleanup_days = int(pc.clamp_number(args.cleanup_days, 0, 3650, DEFAULT_CLEANUP_DAYS))
    max_bytes = max_mb * 1024 * 1024
    ensure_root()

    worker = try_worker_lock()
    if worker is None:
        pc.emit({"ok": True, "already": True})
    try:
        deleted = startup_pass(cleanup_days)
        completed, failed = run_loop(parallel, max_bytes)
    finally:
        try:
            fcntl.flock(worker.fileno(), fcntl.LOCK_UN)
        finally:
            worker.close()
    pc.emit({"ok": True, "completed": completed, "failed": failed,
             "cleaned": deleted})


def run_loop(parallel, max_bytes):
    active = {}
    completed = 0
    failed = 0
    index = None
    index_at = 0

    while True:
        with StateLock():
            state = load_state()
            # Cancellations: the record went away, or is no longer ours.
            for episode_id, transfer in list(active.items()):
                rec = state["items"].get(episode_id)
                if not rec or rec["state"] != "downloading":
                    transfer.kill("cancelled")

            queued = [eid for eid, rec in sorted(state["items"].items(),
                                                 key=lambda kv: kv[1]["added"])
                      if rec["state"] == "queued" and eid not in active]
            changed = False
            if queued and len(active) < parallel:
                if index is None or time.monotonic() - index_at > 30:
                    index = episode_index(pc.load_shows())
                    index_at = time.monotonic()
            for episode_id in queued:
                if len(active) >= parallel:
                    break
                rec = state["items"][episode_id]
                found = index.get(episode_id) if index else None
                if not found:
                    rec["state"] = "failed"
                    rec["error"] = "that episode is no longer in its feed"
                    changed = True
                    failed += 1
                    continue
                show, episode = found
                url, allow_http = download_url(show, episode)
                if not url or pc.url_blocked(url):
                    rec["state"] = "failed"
                    rec["error"] = "that episode has no HTTPS address to download from"
                    changed = True
                    failed += 1
                    continue
                transfer = Transfer(episode_id, show, episode, url, allow_http,
                                    max_bytes, rec["validator"])
                error = transfer.start(resume=not rec["resumeFailed"])
                if error:
                    rec["state"] = "failed"
                    rec["error"] = error
                    failed += 1
                else:
                    rec["state"] = "downloading"
                    rec["error"] = ""
                    active[episode_id] = transfer
                changed = True

            for episode_id, transfer in list(active.items()):
                rec = state["items"].get(episode_id)
                total = transfer.watch()
                if rec and total and rec["total"] != total:
                    rec["total"] = total
                    changed = True
                if rec and transfer.validator != rec["validator"]:
                    rec["validator"] = transfer.validator
                    changed = True
                if transfer.proc.poll() is None:
                    continue
                del active[episode_id]
                outcome, detail = transfer.finish()
                if outcome == "cancelled" or not rec:
                    transfer.discard()
                    continue
                changed = True
                if outcome == "done":
                    rec.update(state="done", file=detail["file"], bytes=detail["bytes"],
                               total=detail["bytes"], error="", done=int(time.time()))
                    completed += 1
                elif outcome == "retry-fresh" and not rec["resumeFailed"]:
                    transfer.discard()
                    rec.update(state="queued", resumeFailed=True, bytes=0,
                               validator="")
                else:
                    rec.update(state="failed", error=str(detail)[:200])
                    failed += 1
            if changed:
                save_state(state)
            if not active and not any(r["state"] == "queued"
                                      for r in state["items"].values()):
                return completed, failed
        time.sleep(POLL_SECONDS)


# ------------------------------------------------------------------ parser

def register(sub):
    p = sub.add_parser("download-status")
    p.set_defaults(run=cmd_status)

    p = sub.add_parser("download-add")
    p.add_argument("episode_id")
    p.set_defaults(run=cmd_add)

    p = sub.add_parser("download-remove")
    p.add_argument("episode_id")
    p.set_defaults(run=cmd_remove)

    p = sub.add_parser("download-clear")
    p.set_defaults(run=cmd_clear)

    p = sub.add_parser("download-show")
    p.add_argument("show_id")
    p.add_argument("value", choices=["on", "off", "default"])
    p.set_defaults(run=cmd_show)

    p = sub.add_parser("download-run")
    p.add_argument("--parallel", default=DEFAULT_PARALLEL)
    p.add_argument("--max-mb", default=DEFAULT_MAX_MB)
    p.add_argument("--cleanup-days", default=DEFAULT_CLEANUP_DAYS)
    p.set_defaults(run=cmd_run)
