# Keeping this fork in step with upstream

This fork is `matt-shearing/omarchy-podcasts`. It adds offline downloads to
[Bottelet/omarchy-podcasts](https://github.com/Bottelet/omarchy-podcasts).
Most of the addition lives in new files (`scripts/downloads.py`,
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
     `offline().register(sub)` and the `offline()` function in `build_parser`
   - `Panel.qml`: the `offline` property, the source line in `playEpisode`,
     `streamInstead` in the `end-file` error branch, `offline.kick()` after a
     refresh, `case "d"` in `handleTextKey`, `setDownloadSetting`, and the
     key legends
   - `EpisodeRow.qml`: the `DownloadButton` and the download label
   - `SettingsView.qml`: the `DownloadSettings` block
   - `ShowsView.qml`: the auto-download switch
   - `manifest.json`: three `download*` defaults and schema entries
   - `Model.js`: the section at the end of the file
   - `tests/run.sh`: `source "$HERE/downloads.sh"`
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
