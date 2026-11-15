# App market

The **App market** tile on the desktop lists the mini programs published on the host's market; installing and upgrading happen there. The page is a storefront only: the list comes from the market service on the engine host (AppHub, the wanqi project's server). When the host doesn't have it, or it isn't running, the page shows **AppHub unreachable**.

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
4. Connected but the list is empty: install at least one package with `wanqi bundle install` on the host — an empty market has nothing to show.

See [Engine and remote hosts](03-engine-hosts.md) for choosing a connection, and [Plugins](08-plugins.md) for DSH plugins and the plugin market.
