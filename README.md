# DevStats

A macOS menu bar app showing resource usage for this Mac and a Linux devbox side by side.

The menu bar shows RAM usage for both machines (`Mac 78% · Dev 15%`). The panel adds CPU with 2-minute history, memory, swap, disk, load, and the top memory users grouped by process name.

- **Mac** stats come straight from the kernel (Mach host statistics, sysctl, libproc). The memory bar is tinted by macOS memory pressure rather than used %, since macOS keeps RAM full on purpose.
- **Devbox** stats come from one `ssh` command reading `/proc` and `df`. The connection is reused via SSH multiplexing (passed on the command line, so `~/.ssh/config` is untouched), so polls cost ~30ms. Nothing needs to be installed on the devbox.
- Polls every second while the panel is open, every 5 seconds while it's closed, and backs off while the devbox is unreachable.

## Requirements

- macOS 14+, Xcode with Swift 6.2+
- An SSH host named `devbox` with key-based auth. Use a different host with:

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
