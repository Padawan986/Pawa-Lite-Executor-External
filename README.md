# Pawa-Lite-Executor-External

Release channel for **Pawa-Lite(Beta)V2** (external Roblox executor UI + FAPI).

The app fetches from here on every start (background update check):

| File         | Purpose                                              |
|--------------|------------------------------------------------------|
| `version.json` | `{app_version, init_version, notes}` – compared against the local marker; a new `init_version` triggers a download |
| `init.luau`    | Inject payload served to the game (compiled at inject time) |

`init.luau` is only accepted when it contains `identifyexecutor` and is larger
than 1 KB, otherwise the bundled copy keeps being used.
