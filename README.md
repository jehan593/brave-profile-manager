# brave-profile-manager

> **FYI:** This project is fully vibe coded for my personal use and taste. It's shared publicly in case it's useful to you. Feel free to fork it and adapt it to your needs.

Creates independent Brave profiles as separate launchers, each with its own data folder, icon and taskbar group.

Use this over Brave's built-in profile switcher when you want each profile pinned as its own app with its own icon and its own default-browser entry, on Linux or Windows.

**Linux**

Needs **ImageMagick**.

```bash
curl -fsSL https://raw.githubusercontent.com/jehan593/brave-profile-manager/main/brave-profile-manager.sh | bash
```

**Windows**

```powershell
powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/jehan593/brave-profile-manager/main/brave-profile-manager.ps1 | iex"
```

`1` = add profiles, `2` = remove.

MIT — [LICENSE](LICENSE).
