# The Feed view (fork addition). Sourced by tests/run.sh after downloads.sh.

section "Feed view"

SAVED_STATE_DIR="$OMARCHY_PODCASTS_DIR"
export OMARCHY_PODCASTS_DIR="$WORK/feedstate"

routes "{\"https://example.com/a.xml\": {\"fixture\": \"full.xml\"}, \"https://example.com/b.xml\": {\"fixture\": \"full.xml\"}}"
run add "https://example.com/a.xml"
FEED_A="$(printf '%s' "$OUT" | jq -r '.show.id')"
run add "https://example.com/b.xml"
FEED_B="$(printf '%s' "$OUT" | jq -r '.show.id')"
run show-set "$FEED_B" mode ignore

# Re-date the fixture episodes: show A's first two 1 and 5 days ago, show B's
# first one 3 days ago, everything else 40 days ago.
python3 - "$OMARCHY_PODCASTS_DIR/episodes" "$FEED_A" "$FEED_B" <<'PYEOF'
import json, os, sys, time
now = int(time.time())
for show, ages in ((sys.argv[2], [1, 5]), (sys.argv[3], [3])):
    path = os.path.join(sys.argv[1], show + ".json")
    eps = json.load(open(path))
    for i, ep in enumerate(eps):
        ep["pub"] = now - (ages[i] if i < len(ages) else 40) * 86400
    json.dump(eps, open(path, "w"))
PYEOF

run feed --days 7
check "the feed holds every show's recent episodes" '.total' '3'
check "…newest first" '[.episodes[].pub] == ([.episodes[].pub] | sort | reverse)' 'true'
check "…including shows set to ignore" "[.episodes[].showId] | index(\"$FEED_B\") != null" 'true'
check "…with the show's name on each" '.episodes[0].show != ""' 'true'
run feed --days 60
check "a wider window reaches further back" '.total > 3' 'true'
run feed --days 0
check "the window is at least a day" '.days' '1'

FIRST="$(python3 "$SCRIPT" feed --days 7 | jq -r '.episodes[0].id')"
run queue add "$FIRST"
run feed --days 7
check "a queued episode is marked as queued" '.episodes[0].queued' 'true'
check "…and stays in the feed" '.total' '3'
run triage archive "$FIRST"
run feed --days 7
check "an archived episode stays in the feed too" '.total' '3'

if command -v node >/dev/null 2>&1; then
  reply="$(node -e 'const M=require(process.argv[1]); console.log(JSON.stringify(M.feedCommand(process.argv[2] + "/", 14)))' "$PLUGIN/Model.js" "$PLUGIN/scripts" | jq -r '.[]' | { mapfile -t A; "${A[@]}"; })"
  if printf '%s' "$reply" | jq -e '.ok' >/dev/null 2>&1; then ok "feed answers the panel's command with JSON"
  else bad "feed answers the panel's command with JSON" "$(printf '%s' "$reply" | head -c 120)"; fi
fi

export OMARCHY_PODCASTS_DIR="$SAVED_STATE_DIR"
