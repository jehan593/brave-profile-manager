# brave-profile-manager

A bash script to create and remove fully independent Brave browser profiles
as `.desktop` launchers on Linux, based on the approach described in
[this gist](https://gist.github.com/pannal/d398ee9801a8c6d0e44b1027af193610).

Each profile gets its own `--user-data-dir` (so it behaves as a completely
separate browser instance) and its own icon, generated from your installed
Brave variant with a colored dot composited on top so profiles are easy to
tell apart in the taskbar and app launcher.

## Features

**Add**
- Detects installed Brave variants (stable, Beta, Nightly, Origin + its
  Beta/Nightly, snap, flatpak) and lets you pick one
- Creates a separate `--user-data-dir` per profile, so KDE/GNOME treat each
  as its own app instead of grouping windows together
- Extracts the icon from the selected variant and draws a colored dot (your
  choice of color) in the top-right corner
- Writes a `.desktop` launcher named exactly what you typed

**Remove**
- Lists launchers previously created by this script
- Always removes the `.desktop` file and generated icon
- Only deletes the profile's browsing data if you explicitly confirm,
  per profile

## Requirements

- bash, coreutils
- ImageMagick (`convert`/`magick` + `identify`) — required for the add path
  only; remove has no extra dependencies
- An installed Brave variant (stable, Beta, Nightly, Origin, snap, or
  flatpak)

## Usage

```bash
./brave-profile-manager.sh
```

You'll be prompted to add or remove profiles interactively.

## License

MIT — see [LICENSE](LICENSE).
