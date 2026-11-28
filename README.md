# brave-profile-manager

> **FYI:** This project is fully vibe coded for my personal use and taste. It's shared publicly in case it's useful to you. Feel free to fork it and adapt it to your needs.

Brave already has a profile switcher. This exists for the case it doesn't cover: making each profile a separate app and browser entry on Linux and Windows, with its own data folder, icon, taskbar group, launcher, and default-browser registration.

So each profile shows up on its own in default-app settings and in link/file "open with" dialogs. The script only registers the choices; you choose the default yourself.

Removing one profile never uninstalls Brave or the other profiles. Use `2` in the script, or the right-click uninstall action on that profile's launcher. No separate "Uninstall …" entry is added to your app menu.

**Linux**

Needs **ImageMagick** for creating profiles. Paths, Brave variants, icons and MIME types are discovered from your XDG directories and installed Brave registration; nothing is tied to a particular distribution or desktop environment.

Each profile is registered as its own browser app and gets a saved uninstaller used by menu option 2 and the right-click action. Your chosen default browser is never changed for you.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jehan593/brave-profile-manager/main/brave-profile-manager.sh)
```

**Windows**

```powershell
powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/jehan593/brave-profile-manager/main/brave-profile-manager.ps1 | iex"
```

`1` = add profiles, `2` = remove.

MIT — [LICENSE](LICENSE).
