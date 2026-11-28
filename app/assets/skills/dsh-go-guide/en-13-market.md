# App market

The **App market** on the desktop has two tabs. **Installed** lists the **Mini program**s on this phone — they are all installed in the background: packages published on the host with the wanqi CLI are silently synced onto the phone, and **Open** launches one. The **Apps** tab is the storefront for external mini programs, coming later; for now it shows **App market under development**. The page reads from the market service on the engine host (AppHub, the wanqi project's server); when it can't, the page shows **AppHub unreachable**.

## Where the market service runs

- The market service (AppHub) runs on the engine host on port 7610; the market page, mini-program notices and upgrade checks all read from it.
- Reaching it: an SSH host forwards port 7610 automatically when the link comes up; emulators and USB debugging go through adb reverse; a host reached over DSH Remote relay needs the market relay plugin installed on that host.
- The server and the packages live in two repositories: wanqi (the server and the wanqi CLI) and dsh-go-miniprograms (release packages). Both ship with the Wanqi project and are not published separately yet.

## Installing the backend and the wanqi CLI on the host

You need git and Dart on the host (the Flutter SDK provides the dart command); on macOS the database is Homebrew's MariaDB — install it first with `brew install mariadb` if missing.

```bash
git clone <wanqi repository> wanqi && cd wanqi
git clone <mini-program repository> dsh-go-miniprograms   # next to wanqi
bash server/tool/install-cli.sh                # creates ~/.local/bin/wanqi
wanqi service doctor                           # health check; repairs in dependency order
wanqi service start server                     # starts the market server (default port 7610)
```

With the global command in place, wanqi works from any directory; for a background service that survives reboots, run `wanqi service install` once (registers the launchd service).

Put a mini program on the market (release packages live in `dist/` of the mini-program repository):

```bash
wanqi bundle install ../dsh-go-miniprograms/dist/wx5b8e2f4a9c1d7e60-10.zip
```

Handy commands: `wanqi service status` for the health table, `wanqi service logs server -f` to follow the logs, `wanqi bundle upgrade <zip>` to upgrade, `wanqi bundle rollback --app <id>` to roll back, `wanqi bundle remove --app <id>` to uninstall.

> install-cli.sh bakes local paths into the generated command; override them with the WANQI_REPO and DART_BIN environment variables. Without dart, wanqi service commands fall back to the lifecycle script.

## When it says AppHub unreachable

1. Check on the host first: `curl -s http://127.0.0.1:7610/api/v1/apps` should return the app list; if not, the server isn't up — run `wanqi service doctor`.
2. SSH host: reconnect the host (the port forwards only while the link is up), then pull to refresh the market page.
3. DSH Remote relay: install the market relay plugin on that host first, then reconnect.
4. Connected but **Installed** is empty: install at least one package with `wanqi bundle install` on the host — the phone picks it up automatically.

## Jumping to a mini program page from a chat

A reply can carry a mini program jump card: a card with the app's icon and the page's name — tap it to open that page of that mini program (an app that isn't installed yet installs first, then opens). The plain-link form is tappable the same way.

- The card points at a mini program in the **Installed** list; if the app doesn't exist or the host is offline, tapping says the link can't be opened.
- The card markup (for troubleshooting): `<miniapp app="appId" title="page name" path="page path"></miniapp>`; the plain link is `dshgo://mini/appId?path=page path`.
- Omitting `path` opens the mini program's home page; opening a mini program consumes its unread badge, just like tapping its desktop tile.

See [Engine and remote hosts](03-engine-hosts.md) for choosing a connection, and [Plugins](08-plugins.md) for DSH plugins and the plugin market.
