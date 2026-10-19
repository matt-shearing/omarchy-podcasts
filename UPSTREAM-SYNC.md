# Keeping this fork in step with upstream

This fork is `matt-shearing/omarchy-podcasts`. It adds offline downloads to
[Bottelet/omarchy-podcasts](https://github.com/Bottelet/omarchy-podcasts).
It also adds a Feed tab, a volume control, a player that survives shell
restarts, and episode names for MPRIS. Most of the additions live in new files
(`scripts/downloads.py`, `scripts/feed.py`, `Feed.qml`, `FeedView.qml`,
`VolumeRow.qml`, `PlayerOwner.js`,
`Downloads.qml`, `DownloadButton.qml`, `DownloadSettings.qml`,
`tests/downloads.sh`, `UPSTREAM-SYNC.md`). Upstream's files carry only short
hooks, each marked "fork addition", so most upstream changes merge without
conflicts.

## One-time setup

`gh repo fork --clone` already added the `upstream` remote. On a fresh clone,
add it:

```bash
git remote add upstream https://github.com/Bottelet/omarchy-podcasts.git
```

## Pull upstream changes

1. Fetch upstream and look at what is new:

   ```bash
   git fetch upstream
   ```

   ```bash
   git log --oneline main..upstream/main
   ```

2. Merge it into `main`. A merge keeps the history the installed plugin
   already follows, so `omarchy plugin update` works without a force-pull:

   ```bash
   git checkout main
   ```

   ```bash
   git merge upstream/main
   ```

3. If there are conflicts, they will be at the hooks. Keep upstream's change
   and put the fork's line back beside it. The hooks are:
   - `scripts/podcasts.py`: `offline().note_new(...)` in `cmd_refresh`,
     the two `register(sub)` lines and the `fork_module()` / `offline()`
     functions after `build_parser`
   - `Panel.qml`: the `offline` property, the source line in `playEpisode`,
     `streamInstead` in the `end-file` error branch, `offline.kick()` after a
     refresh, `case "d"` in `handleTextKey`, `setDownloadSetting`, the
     `feed` property, the `"feed"` cases in `rows`, the cursor and key
     handlers, the Feed tab and `FeedView`, the 1–5 digit keys, the volume
     block and its `applyVolume()` calls, `↑`/`↓` in the Player, `case "m"`,
     the persistent-player block (`startDetached`, `attachToRunningPlayer`,
     `playerGone`, `onDestruction`), `force-media-title` in `sendLoad`,
     `playing` first in `onOpened`, and the key legends
   - `PlayerView.qml`: the `VolumeRow`
   - `EpisodeRow.qml`: the `DownloadButton` and the download label
   - `SettingsView.qml`: the `DownloadSettings` block
   - `ShowsView.qml`: the auto-download switch
   - `manifest.json`: the `download*`, `feedDays` and `volume` defaults and schema
     entries
   - `Model.js`: the section at the end of the file
   - `tests/run.sh`: the `source` lines for `downloads.sh` and `feed.sh`
   - `tests/fake-curl.py`: `-C`, `--speed-*` and `serve_audio`
   - `README.md` / `OMARCHY_PLUGIN.md`: the download sections

4. Run the tests. All must pass:

   ```bash
   tests/run.sh
   ```

5. Push, then update the installed plugin:

   ```bash
   git push origin main
   ```

   ```bash
   omarchy plugin update bottelet.podcasts
   ```

   The shell keeps an already-loaded panel in memory. If a change to a QML
   file does not show up, restart the shell:

   ```bash
   omarchy restart shell
   ```

## If upstream ships its own offline downloads

Upstream has said it plans downloads. When that lands, compare the two
before merging. If upstream's version covers what this fork does, drop the
fork's files and hooks in one commit and keep any downloaded files by moving
them to wherever upstream stores them. Do not run two download systems side
by side.
