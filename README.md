# KidSafe

*[Français](README.fr.md)*

**Free parental control for macOS, built on [Privoxy](https://www.privoxy.org/).**
A menu bar app (English and French) that blocks unwanted websites for the whole Mac: adult content,
gambling, scams, social networks on a schedule, and any domain you choose.

> **Test version.** Everything installs and uninstalls from the `.dmg`, with Privoxy built in.
> KidSafe is not yet signed by Apple, so macOS asks for confirmation the first time.

**[⬇︎ Download KidSafe.dmg](https://github.com/lls-hcr/kidsafe/releases/latest/download/KidSafe.dmg)** ·
[Release notes](https://github.com/lls-hcr/kidsafe/releases) ·
[Project page](https://mizuki.ch/documentation/kidsafe/)

## Install

1. Open `KidSafe.dmg` and drag **KidSafe** to **Applications**.
2. Open KidSafe. The first time, macOS blocks it because it isn't signed yet: go to
   **System Settings → Privacy & Security → Open Anyway**.
3. That's it: on first launch, KidSafe turns protection on by itself (green shield in the menu bar).
   On a standard account, macOS asks once for an administrator password.

Nothing else to install: Privoxy is built into the app. Quitting KidSafe removes the filter and gives
the Mac its normal connection back.

## Updates

KidSafe checks GitHub for new versions once a week (or on demand: shield menu → **Check for Updates…**).
With **Install and Relaunch** (or automatically, if enabled in Settings → General), it downloads the new
`.dmg`, verifies its SHA-256 fingerprint against the one GitHub publishes, checks that it really is a newer
KidSafe with an intact signature, then quits (filter removed, Privoxy stopped), replaces itself and relaunches.
Settings are kept. Filtering pauses for a few seconds during the update.

## Uninstall

Open `KidSafe.dmg` and double-click **Uninstall KidSafe** (or, in the app, **Settings → General →
Uninstall KidSafe…**). It removes the filter, stops Privoxy, deletes all KidSafe settings and moves the app
to the Trash. If a parent password is set, it is required.

## Features

- **Blocklist categories**: adult content (on by default), bypass tools (VPNs, proxies, encrypted DNS),
  scams and malware, gambling, violence, drugs, dating, social networks, online games, ads.
  Plus a library of free lists, any list from a web address, or a file from your Mac
  (Adblock, hosts and plain domain formats).
- **Social networks**: Facebook, Instagram, TikTok, X, Snapchat, YouTube, Threads, WhatsApp, Telegram,
  Discord, Reddit, Twitch, Pinterest, BeReal. Each can be allowed, always blocked, blocked during time slots
  (e.g. at night) or allowed only during time slots (e.g. Wednesday afternoon).
- **Your own domains**: block or always allow any domain (and its subdomains).
- **Strict mode**: everything is blocked except the allowlist, for younger children.
- **Optional parent password** for every change, pausing and quitting.
- **Filtering switch** in the menu bar to pause without deleting anything.
- **Automatic list updates**, from every hour to every week (or never).
- **The Mac never loses its connection**: if Privoxy stops, KidSafe restarts it, or removes the proxy
  if it can't. Only KidSafe's own proxy setting is ever changed.

- **Monitor** (shield menu): a small floating window with live counters (requests filtered, blocked, percentage,
  domains on lists, last block), and a **detailed view**: a self-contained local HTML page with tiles, hourly and
  daily charts, top blocked domains, blocks by category and latest blocks. Nothing runs while the window is closed.
- **Advanced tab** (parent password, with a warning): Privoxy port (picked automatically if busy, or set by hand),
  Privoxy's browser editor (`http://p.p`, closes by itself after one hour), your own Privoxy rules (`user.action`,
  checked before being applied), blocked-sites log, domains that skip the filter, Privoxy status, restart and reset.

**Limits**: filtering works per domain (no HTTPS interception), so blocked HTTPS sites show a browser
error rather than a block page. Time slots are applied while the app is running. A child with an
administrator account can still change system settings; use a standard account for children.

## Build from source

Requires macOS 14+, the Xcode Command Line Tools (full Xcode not needed) and `autoconf`
(`brew install autoconf`, only to build Privoxy).

```sh
scripts/test.sh                      # unit tests
scripts/build-app.sh                 # build/KidSafe.app for this Mac
scripts/build-app.sh --universal     # Apple Silicon + Intel
scripts/build-privoxy.sh             # Privoxy 4.2.0 + PCRE2 from source, universal (called by build-app.sh)
scripts/make-dmg.sh                  # build/KidSafe.dmg with a designed window (uses dmgbuild in build/venv)
swift scripts/make-icon.swift Resources/AppIcon.png   # redraws the icon
```

| Target | Role |
|---|---|
| `KidSafeCore` | Blocklist parsing, Privoxy file generation, install with config test and rollback, catalog, schedules, translations |
| `KidSafeApp` (product `KidSafe`) | SwiftUI menu bar app and settings window |
| `KidSafeUninstaller` (`Uninstall KidSafe.app`) | Uninstaller shipped in the `.dmg` |
| `kidsafe-blocklist` | Command-line tool (replaces the old `privoxy-blocklist.sh` and `blocklist2privoxy.sh` scripts) |

**Built-in Privoxy**: the app contains Privoxy (`Contents/Helpers/privoxy`) and its default files
(`Contents/Resources/privoxy-conf`). On first launch they are installed in
`~/Library/Application Support/KidSafe/privoxy/` and Privoxy listens on `127.0.0.1:8128`, a dedicated port that
never conflicts with another Privoxy. KidSafe starts it on launch and stops it on quit.

The app and the CLI share the same catalog: `~/Library/Application Support/KidSafe/catalog.json`.
For development, `KIDSAFE_SUPPORT_DIR` and `KIDSAFE_PRIVOXY_CONF` isolate the app from your real configuration.

Build options (environment variables for `scripts/build-app.sh`): `KIDSAFE_DONATE_URL`, `KIDSAFE_ISSUES_URL`,
`KIDSAFE_WEBSITE_URL`, `KIDSAFE_SOURCE_URL`. The feedback email is read from `scripts/local.env`
(`KIDSAFE_FEEDBACK_EMAIL=…`), which git ignores.

### Command line

```sh
B=build/KidSafe.app/Contents/MacOS/kidsafe-blocklist
$B lists
$B enable gambling
$B enable adult-ut1 --yes                       # large list: warning without --yes
$B library
$B add-list --from-library easylist
$B add-list --name "My list" --url https://example.org/list.txt
$B add-list --file ~/Documents/my-list.txt      # from disk
$B remove-list my-list
$B block roblox.com | allow example.org
$B pause | resume                               # asks for the parent password if set
$B update [--dry-run] [--remove-legacy]         # download, install, test, roll back on error
$B uninstall
```

The CLI follows the system language; `KIDSAFE_LANG=en` or `KIDSAFE_LANG=fr` forces it.

### Translations

`Sources/KidSafeCore/Resources/{en,fr}.lproj/Localizable.strings`. Both files must have the same keys.

### Measurements (Apple Silicon Mac, Privoxy 4.2.0)

| Lists loaded | Domains | Privoxy memory | Request time | Reload |
|---|---|---|---|---|
| HaGeZi NSFW + UT1 gambling | ~180,000 | 41 MB | ~36 ms (same as without lists) | instant |
| Full UT1 adult list | 4.6 M | 786 MB | +~70 ms | ~4 s |

## Roadmap

- Apple signature and notarization (no more “Open Anyway”).
- Root helper (LaunchDaemon) protected by the parent password, so filtering and time slots keep running
  even when the app is closed; settings moved to
  `/Library/Application Support/KidSafe`, where a child can't change them.
- Log of blocked attempts, local block page.

## Feedback and support

- Ideas and problems: [open an issue](https://github.com/lls-hcr/kidsafe/issues/new), or use **Send Feedback…** in the app.
- Support the project: [GitHub Sponsors](https://github.com/sponsors/lls-hcr).

## License

KidSafe is released under the GNU GPL v3 (see [LICENSE](LICENSE)). The built-in Privoxy is GPL v2 or later:
its exact source code is downloaded and verified by `scripts/build-privoxy.sh`
([Privoxy 4.2.0 sources](https://sourceforge.net/projects/ijbswa/files/Sources/4.2.0%20%28stable%29/),
[PCRE2 10.49](https://github.com/PCRE2Project/pcre2/releases/tag/pcre2-10.49), BSD license).
Blocklists keep their own licenses (listed in the catalog): HaGeZi (GPL-3.0), UT1 Toulouse Capitole (CC BY-SA 4.0),
StevenBlack (MIT), Block List Project (Unlicense), EasyList (GPL-3.0 / CC BY-SA 3.0).
