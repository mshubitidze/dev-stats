# DevStats

A macOS menu bar app showing resource usage for this Mac and a Linux devbox side by side.

The menu bar shows RAM usage for both machines behind Apple and Ubuntu logos, plus the Claude account with the most 5-hour room left behind the Claude logo. The panel adds CPU with 2-minute history, memory, swap, disk, load, the top memory users grouped by process name, and subscription limits.

- **Mac** stats come straight from the kernel (Mach host statistics, sysctl, libproc). The memory bar is tinted by macOS memory pressure rather than used %, since macOS keeps RAM full on purpose.
- **Devbox** stats come from one `ssh` command reading `/proc` and `df`. The connection is reused via SSH multiplexing (passed on the command line, so `~/.ssh/config` is untouched), so polls cost ~30ms. Nothing needs to be installed on the devbox.
- **Limits** shows the 5-hour and weekly subscription windows for every Claude and Codex account in [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) on the devbox. A small Python script runs on the devbox, reads CLIProxyAPI's auth files (`~/.cli-proxy-api`), and queries the usage endpoints Claude Code and Codex use for their own usage screens, so OAuth tokens never leave the devbox. These endpoints are private and may change.
- Polls every second while the panel is open, every 5 seconds while it's closed, and backs off while the devbox is unreachable. Limits refresh every 5 minutes (15 while rate limited), and the last result is reused across relaunches.

## Requirements

- macOS 26+, Xcode with Swift 6.2+
- An SSH host named `devbox` with key-based auth, and `python3` on it for the limits section. Use a different host with:

  ```sh
  defaults write com.misho.DevStats devboxHost <ssh-host>
  ```

## Build

```sh
./build-app.sh                      # builds build/DevStats.app
cp -R build/DevStats.app /Applications/
swift test                          # parser tests
```

Enable "Open at Login" from the panel.

Logo paths are from [Simple Icons](https://simpleicons.org) (CC0); the marks are trademarks of their owners.
