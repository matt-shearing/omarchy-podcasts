# Offline downloads (fork addition). Sourced by tests/run.sh, so it shares
# run/check/routes, the stub curl and $WORK. It keeps its own state directory
# so nothing here depends on what the upstream sections left behind.

section "Offline downloads"

SAVED_STATE_DIR="$OMARCHY_PODCASTS_DIR"
export OMARCHY_PODCASTS_DIR="$WORK/dlstate"
DL="$OMARCHY_PODCASTS_DIR/downloads"

# The bytes the stub serves for a given size and ETag, so a finished file can
# be compared with what the server actually sent.
expected_sha() {
  python3 - "$HERE/fake-curl.py" "$1" "$2" <<'PYEOF'
import hashlib, importlib.util, sys
spec = importlib.util.spec_from_file_location("fc", sys.argv[1])
fc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fc)
print(hashlib.sha256(fc.audio_body(int(sys.argv[2]), sys.argv[3])).hexdigest())
PYEOF
}
sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
ep_id() { python3 "$SCRIPT" episodes -- "$1" | jq -r --arg u "$2" '.episodes[] | select(.url == $u) | .id'; }
dl_run() { run download-run --parallel "${1:-2}" --max-mb "${2:-1024}" --cleanup-days "${3:-7}"; }
dl_state() { run download-status; }

DLFEED="https://example.com/dl.xml"
routes "{\"$DLFEED\": {\"fixture\": \"full.xml\"}}"
run add "$DLFEED"
DLSHOW="$(printf '%s' "$OUT" | jq -r '.show.id')"
EP_FULL="$(ep_id "$DLSHOW" https://example.com/full.mp3)"
EP_NOGUID="$(ep_id "$DLSHOW" https://example.com/noguid.mp3)"
EP_BADCH="$(ep_id "$DLSHOW" https://example.com/badch.mp3)"
EP_OLDEST="$(ep_id "$DLSHOW" https://example.com/oldest.mp3)"
EP_HTTP="$(ep_id "$DLSHOW" http://example.com/old.mp3)"

dl_state
check "nothing is downloaded on a fresh install" '.items | length' '0'
check "…and nothing is in use on disk" '.usedBytes' '0'

# ---- success, through a tracking-prefix redirect like real podcast CDNs
routes "{\"$DLFEED\": {\"fixture\": \"full.xml\"},
  \"https://example.com/full.mp3\": {\"audio\": 300000, \"etag\": \"\\\"a1\\\"\", \"location\": \"https://cdn.example.com/a/full.mp3\"}}"
run download-add "$EP_FULL"
check "download-add queues the episode" ".items[\"$EP_FULL\"].state" 'queued'
dl_run
check "the worker finishes the download" '.completed' '1'
dl_state
check "the episode is marked downloaded" ".items[\"$EP_FULL\"].state" 'done'
check "…stored as <show>/<episode>.mp3" ".items[\"$EP_FULL\"].path" "$DL/$DLSHOW/$EP_FULL.mp3"
check "…with the size the server sent" ".items[\"$EP_FULL\"].bytes" '300000'
check "disk use counts it" '.usedBytes' '300000'
if [[ "$(sha_of "$DL/$DLSHOW/$EP_FULL.mp3")" == "$(expected_sha 300000 '"a1"')" ]]; then
  ok "…byte for byte what the server sent"
else bad "…byte for byte what the server sent"; fi
if [[ "$(stat -c %a "$DL/$DLSHOW/$EP_FULL.mp3")" == "600" && "$(stat -c %a "$DL")" == "700" ]]; then
  ok "downloads are private (0600 files, 0700 directory)"
else bad "downloads are private (0600 files, 0700 directory)" "$(stat -c '%a %n' "$DL" "$DL/$DLSHOW/$EP_FULL.mp3")"; fi
if [[ ! -e "$DL/$DLSHOW/$EP_FULL.part" && ! -e "$DL/$DLSHOW/$EP_FULL.hdr" ]]; then
  ok "no .part or header file is left behind"
else bad "no .part or header file is left behind"; fi
run download-add "$EP_FULL"
check "adding a finished download again changes nothing" ".items[\"$EP_FULL\"].state" 'done'

# ---- a dropped connection keeps the partial, and a retry resumes it
routes "{\"$DLFEED\": {\"fixture\": \"full.xml\"},
  \"https://example.com/noguid.mp3\": {\"audio\": 200000, \"etag\": \"\\\"b1\\\"\", \"cut_at\": 80000}}"
run download-add "$EP_NOGUID"
dl_run
check "a dropped transfer is reported as failed" '.failed' '1'
dl_state
check "…with a reason" ".items[\"$EP_NOGUID\"].state" 'failed'
if [[ "$(stat -c %s "$DL/$DLSHOW/$EP_NOGUID.part" 2>/dev/null)" == "80000" ]]; then
  ok "…and the partial file is kept for a resume"
else bad "…and the partial file is kept for a resume"; fi
dl_run
check "a failed download is not retried on its own" '.completed + .failed' '0'
routes "{\"$DLFEED\": {\"fixture\": \"full.xml\"},
  \"https://example.com/noguid.mp3\": {\"audio\": 200000, \"etag\": \"\\\"b1\\\"\"}}"
run download-add "$EP_NOGUID"
dl_run
dl_state
check "retrying resumes and finishes" ".items[\"$EP_NOGUID\"].state" 'done'
if [[ "$(sha_of "$DL/$DLSHOW/$EP_NOGUID.mp3")" == "$(expected_sha 200000 '"b1"')" ]]; then
  ok "…and the resumed file is exactly the episode"
else bad "…and the resumed file is exactly the episode"; fi

# ---- the file changed between attempts (dynamic ad insertion): restart
routes "{\"$DLFEED\": {\"fixture\": \"full.xml\"},
  \"https://example.com/badch.mp3\": {\"audio\": 150000, \"etag\": \"\\\"c1\\\"\", \"cut_at\": 50000}}"
run download-add "$EP_BADCH"
dl_run
routes "{\"$DLFEED\": {\"fixture\": \"full.xml\"},
  \"https://example.com/badch.mp3\": {\"audio\": 160000, \"etag\": \"\\\"c2\\\"\"}}"
run download-add "$EP_BADCH"
dl_run
dl_state
check "a file that changed since the partial still downloads" ".items[\"$EP_BADCH\"].state" 'done'
if [[ "$(sha_of "$DL/$DLSHOW/$EP_BADCH.mp3")" == "$(expected_sha 160000 '"c2"')" ]]; then
  ok "…from scratch, never spliced onto the old partial"
else bad "…from scratch, never spliced onto the old partial"; fi

# ---- a shell killed mid-download: the worker resumes at next start
routes "{\"$DLFEED\": {\"fixture\": \"full.xml\"},
  \"https://example.com/oldest.mp3\": {\"audio\": 120000, \"etag\": \"\\\"d1\\\"\"}}"
python3 - "$HERE/fake-curl.py" "$DL/$DLSHOW/$EP_OLDEST.part" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fc", sys.argv[1])
fc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fc)
open(sys.argv[2], "wb").write(fc.audio_body(120000, '"d1"')[:40000])
PYEOF
jq --arg e "$EP_OLDEST" --arg s "$DLSHOW" \
  '.items[$e] = {show: $s, state: "downloading", file: "", bytes: 0, total: 120000,
                 error: "", added: 1, done: 0, playedSeen: 0, resumeFailed: false,
                 validator: "\"d1\""}' \
  "$OMARCHY_PODCASTS_DIR/downloads.json" > "$WORK/dl.json" && mv "$WORK/dl.json" "$OMARCHY_PODCASTS_DIR/downloads.json"
: > "$DL/$DLSHOW/0123456789abcdef.part"
dl_run
dl_state
check "an interrupted download resumes when the worker starts" ".items[\"$EP_OLDEST\"].state" 'done'
if [[ "$(sha_of "$DL/$DLSHOW/$EP_OLDEST.mp3")" == "$(expected_sha 120000 '"d1"')" ]]; then
  ok "…completing the partial correctly"
else bad "…completing the partial correctly"; fi
if [[ ! -e "$DL/$DLSHOW/0123456789abcdef.part" ]]; then
  ok "an orphaned partial nobody wants is cleaned up at start"
else bad "an orphaned partial nobody wants is cleaned up at start"; fi

# ---- refusals
routes "{\"$DLFEED\": {\"fixture\": \"full.xml\"},
  \"https://example.com/old.mp3\": {\"audio\": $((53 * 1024 * 1024))}}"
run download-add "$EP_HTTP"
dl_run 2 50
dl_state
check "an episode over the size cap is refused" ".items[\"$EP_HTTP\"].error" 'episode larger than 50 MB'
if [[ ! -e "$DL/$DLSHOW/$EP_HTTP.part" ]]; then
  ok "…and nothing of it is kept"
else bad "…and nothing of it is kept"; fi

routes "{\"$DLFEED\": {\"fixture\": \"full.xml\"},
  \"https://example.com/old.mp3\": {\"audio\": 5000, \"content_type\": \"text/html; charset=utf-8\"}}"
run download-add "$EP_HTTP"
dl_run
dl_state
check "an HTML page is not saved as an episode" ".items[\"$EP_HTTP\"].state" 'failed'

routes "{\"$DLFEED\": {\"fixture\": \"full.xml\"},
  \"https://example.com/old.mp3\": {\"audio\": 5000, \"remote_ip\": \"127.0.0.1\"}}"
run download-add "$EP_HTTP"
dl_run
dl_state
check "an episode that lands on loopback is refused" ".items[\"$EP_HTTP\"].error" 'that episode leads somewhere a podcast may not reach'

routes "{\"$DLFEED\": {\"fixture\": \"full.xml\"},
  \"https://example.com/old.mp3\": {\"audio\": 7000, \"content_type\": \"video/mp4\"}}"
run download-add "$EP_HTTP"
dl_run
dl_state
check "an http:// enclosure is fetched over HTTPS instead" ".items[\"$EP_HTTP\"].state" 'done'
check "…and a video podcast keeps its own extension" ".items[\"$EP_HTTP\"].path" "$DL/$DLSHOW/$EP_HTTP.mp4"

# ---- parallel limit
run download-clear
check "delete all downloads empties the list" '.items | length' '0'
check "…and the disk" '.usedBytes' '0'
routes "{\"$DLFEED\": {\"fixture\": \"full.xml\"},
  \"https://example.com/full.mp3\": {\"audio\": 1000, \"sleep\": 1.2},
  \"https://example.com/noguid.mp3\": {\"audio\": 1000, \"sleep\": 1.2},
  \"https://example.com/badch.mp3\": {\"audio\": 1000, \"sleep\": 1.2},
  \"https://example.com/oldest.mp3\": {\"audio\": 1000, \"sleep\": 1.2}}"
rm -f "$FAKE_CURL_ROUTES.active"
for ep in "$EP_FULL" "$EP_NOGUID" "$EP_BADCH" "$EP_OLDEST"; do run download-add "$ep"; done
dl_run 2
check "four queued downloads all finish" '.completed' '4'
if [[ "$(cut -d' ' -f2 "$FAKE_CURL_ROUTES.active")" == "2" ]]; then
  ok "…never more than two at once"
else bad "…never more than two at once" "peak $(cat "$FAKE_CURL_ROUTES.active")"; fi
rm -f "$FAKE_CURL_ROUTES.active"
run download-clear
for ep in "$EP_FULL" "$EP_NOGUID" "$EP_BADCH"; do run download-add "$ep"; done
dl_run 1
if [[ "$(cut -d' ' -f2 "$FAKE_CURL_ROUTES.active")" == "1" ]]; then
  ok "a limit of one downloads one at a time"
else bad "a limit of one downloads one at a time" "peak $(cat "$FAKE_CURL_ROUTES.active")"; fi

# ---- cleanup after N days
run position "$EP_FULL" 0 100 --played
dl_run 2 1024 7
dl_state
check "a just-played download is kept" ".items[\"$EP_FULL\"].state" 'done'
jq --arg e "$EP_FULL" '.positions[$e].ts = (now - 8 * 86400 | floor)' \
  "$OMARCHY_PODCASTS_DIR/library.json" > "$WORK/lib.json" && mv "$WORK/lib.json" "$OMARCHY_PODCASTS_DIR/library.json"
dl_run 2 1024 0
dl_state
check "with cleanup set to never, an old played download stays" ".items[\"$EP_FULL\"].state" 'done'
dl_run 2 1024 7
check "a download played eight days ago is deleted at seven" '.cleaned' '1'
dl_state
check "…from the list" ".items[\"$EP_FULL\"] // \"gone\"" 'gone'
if [[ ! -e "$DL/$DLSHOW/$EP_FULL.mp3" ]]; then ok "…and from the disk"; else bad "…and from the disk"; fi
check "an unplayed download is untouched" ".items[\"$EP_NOGUID\"].state" 'done'

run download-remove "$EP_NOGUID"
check "deleting one download removes it" ".items[\"$EP_NOGUID\"] // \"gone\"" 'gone'
if [[ ! -e "$DL/$DLSHOW/$EP_NOGUID.mp3" ]]; then ok "…file and all"; else bad "…file and all"; fi

# ---- auto-download
AUTOFEED="https://example.com/auto.xml"
INBOXFEED="https://example.com/inbox.xml"
routes "{\"$AUTOFEED\": {\"fixture\": \"full.xml\"}, \"$INBOXFEED\": {\"fixture\": \"full.xml\"}}"
run add "$AUTOFEED"
AUTOSHOW="$(printf '%s' "$OUT" | jq -r '.show.id')"
run add "$INBOXFEED"
INBOXSHOW="$(printf '%s' "$OUT" | jq -r '.show.id')"
run show-set "$AUTOSHOW" mode auto
run download-clear
routes "{\"$AUTOFEED\": {\"fixture\": \"full-plus-one.xml\"}, \"$INBOXFEED\": {\"fixture\": \"full-plus-one.xml\"}}"
run refresh --force
AUTO_NEW="$(ep_id "$AUTOSHOW" https://example.com/new.mp3)"
INBOX_NEW="$(ep_id "$INBOXSHOW" https://example.com/new.mp3)"
dl_state
check "a new episode of an auto-queue show is queued for download" ".items[\"$AUTO_NEW\"].state" 'queued'
check "…but not one of an inbox show" ".items[\"$INBOX_NEW\"] // \"none\"" 'none'
check "…and never the back catalogue" '.items | length' '1'
routes "{\"https://example.com/new.mp3\": {\"audio\": 4000}}"
dl_run
dl_state
check "the worker downloads it" ".items[\"$AUTO_NEW\"].state" 'done'

run download-clear
run download-show "$AUTOSHOW" off
run download-show "$INBOXSHOW" on
check "the per-show setting is stored" ".shows[\"$INBOXSHOW\"].auto" 'true'
routes "{\"$AUTOFEED\": {\"fixture\": \"full.xml\"}, \"$INBOXFEED\": {\"fixture\": \"full.xml\"}}"
run refresh --force
routes "{\"$AUTOFEED\": {\"fixture\": \"full-plus-one.xml\"}, \"$INBOXFEED\": {\"fixture\": \"full-plus-one.xml\"}}"
python3 - "$OMARCHY_PODCASTS_DIR/episodes" "$AUTOSHOW" "$INBOXSHOW" <<'PYEOF'
# Forget the new episode so the next poll discovers it again.
import json, os, sys
for show in sys.argv[2:]:
    path = os.path.join(sys.argv[1], show + ".json")
    eps = [e for e in json.load(open(path)) if not e["url"].endswith("/new.mp3")]
    json.dump(eps, open(path, "w"))
PYEOF
run refresh --force
dl_state
check "turning auto-download off for an auto-queue show is honoured" ".items[\"$AUTO_NEW\"] // \"none\"" 'none'
check "turning it on for an inbox show is honoured" ".items[\"$INBOX_NEW\"].state" 'queued'
run download-show "$AUTOSHOW" default
check "default goes back to following the mode" ".shows[\"$AUTOSHOW\"] // \"default\"" 'default'

# ---- unsubscribing takes the show's downloads with it
routes "{\"https://example.com/new.mp3\": {\"audio\": 4000}}"
dl_run
run remove "$INBOXSHOW"
dl_run
dl_state
check "unsubscribing removes that show's downloads" ".items[\"$INBOX_NEW\"] // \"gone\"" 'gone'
if [[ ! -d "$DL/$INBOXSHOW" ]]; then ok "…and its folder"; else bad "…and its folder"; fi

# ---- playback picks the local file first (Model.js)
if command -v node >/dev/null 2>&1; then
  while IFS=$'\t' read -r verdict name detail; do
    [[ -z "${verdict:-}" ]] && continue
    if [[ "$verdict" == "PASS" ]]; then ok "$name"; else bad "$name" "$detail"; fi
  done < <(node -e '
const M = require(process.argv[1])
const ep = { id: "0123456789abcdef", url: "https://example.com/e.mp3" }
const out = []
function expect(name, got, want) {
  out.push([got === want ? "PASS" : "FAIL", name, "want " + want + " got " + got].join("\t"))
}
expect("a downloaded episode plays from disk",
  M.playbackSource({ "0123456789abcdef": { state: "done", path: "/d/x.mp3" } }, ep), "/d/x.mp3")
expect("an episode still downloading streams",
  M.playbackSource({ "0123456789abcdef": { state: "downloading", path: "" } }, ep), ep.url)
expect("a download whose file went missing streams",
  M.playbackSource({ "0123456789abcdef": { state: "missing" } }, ep), ep.url)
expect("an episode never downloaded streams", M.playbackSource({}, ep), ep.url)
expect("a missing file reads as not downloaded",
  M.downloadState({ "0123456789abcdef": { state: "missing" } }, ep.id), "none")
expect("progress is shown as a percentage",
  M.downloadLabel({ state: "downloading", total: 200, bytes: 50, progress: 0.25 }), "downloading 25%")
console.log(out.join("\n"))
' "$PLUGIN/Model.js")

  run download-status
  while IFS=$'\t' read -r label argv_json; do
    [[ -z "${label:-}" ]] && continue
    mapfile -t ARGV < <(printf '%s' "$argv_json" | jq -r '.[]')
    reply="$("${ARGV[@]}" 2>/dev/null)"
    if printf '%s' "$reply" | jq -e 'has("ok")' >/dev/null 2>&1; then
      ok "$label answers with JSON"
    else
      bad "$label answers with JSON" "got: $(printf '%s' "$reply" | head -c 120)"
    fi
  done < <(node -e '
const M = require(process.argv[1]), d = process.argv[2] + "/", show = process.argv[3]
const commands = [
  ["download-status", M.downloadStatusCommand(d)],
  ["download-add",    M.downloadAddCommand(d, "0123456789abcdef")],
  ["download-remove", M.downloadRemoveCommand(d, "0123456789abcdef")],
  ["download-show",   M.downloadShowCommand(d, show, "default")],
  ["download-run",    M.downloadRunCommand(d, 2, 1024, 7)],
  ["download-clear",  M.downloadClearCommand(d)],
]
for (const [label, argv] of commands) console.log(label + "\t" + JSON.stringify(argv))
' "$PLUGIN/Model.js" "$PLUGIN/scripts" "$AUTOSHOW")
fi

export OMARCHY_PODCASTS_DIR="$SAVED_STATE_DIR"
