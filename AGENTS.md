# Repository Guidelines

## Project Overview
Zscaler Split Tunnel enables split tunneling on macOS by removing Zscaler's broad routes that capture all traffic, then adding back specific routes for domains/IPs that should go through Zscaler. Two implementations exist: a standalone Bash daemon and a native macOS SwiftUI app with a privileged helper.

## Project Structure

```
zscaler-split-tunnel.sh          # Standalone Bash daemon (original implementation)
config/
  zscaler-split-tunnel.conf      # Default routes config (domains/IPs routed through Zscaler)
  zscaler-bypass.conf            # Default direct overrides (domains routed directly)
macOS/
  ZscalerSplitTunnel.xcodeproj/  # Xcode project (two targets)
  Shared/                        # Code shared between app and helper
    Constants.swift              # Broad routes, bundle IDs, tuning constants
    ConfigPaths.swift            # Config file locations (~/.config/zscaler-split-tunnel/)
    XPCProtocol.swift            # HelperToolProtocol - XPC interface contract
    XPCTypes.swift               # Codable types for XPC communication
  ZscalerSplitTunnel/            # SwiftUI menu bar app (unprivileged)
    App/                         # App entry point, AppDelegate
    Models/                      # ConfigEntry, ConfigFile, RouteInfo, BroadRoute
    Views/                       # MenuBarView, StatusView, SettingsView, ConfigEditorView
    ViewModels/                  # AppState, HelperConnection (XPC client)
    Services/                    # ConfigService, ZscalerProcessManager, NetworkMonitor
    Utilities/                   # IPValidation
  ZscalerSplitTunnelHelper/      # Privileged helper (runs as root via SMJobBless)
    main.swift                   # NSXPCListener entry point
    HelperTool.swift             # XPC server implementing HelperToolProtocol
    MonitorLoop.swift            # Periodic route refresh loop
    RouteEngine.swift            # Low-level route add/delete via /sbin/route
    BroadRouteManager.swift      # Detects and removes Zscaler broad routes
    ConfigLoader.swift           # Parses routes.conf and bypass.conf
    DNSResolver.swift            # Domain-to-IP resolution with caching
    DNSFlush.swift               # Flushes macOS system DNS cache
    RemoteRouteFetcher.swift     # Fetches route lists from remote URLs
    NetworkDetector.swift        # Detects network changes (gateway/interface changes)
    ZscalerServiceManager.swift  # Start/stop Zscaler processes
    ShellRunner.swift            # Shell command execution helper
    IPValidator.swift            # IP address validation
docs/                            # GitHub Pages site
```

## Build & Run

### Shell script
```bash
chmod +x zscaler-split-tunnel.sh
shellcheck zscaler-split-tunnel.sh          # Lint
./zscaler-split-tunnel.sh --status          # Inspect routes (no sudo)
sudo ./zscaler-split-tunnel.sh --start --verbose  # Run daemon
```

### macOS app (Xcode)
- Open `macOS/ZscalerSplitTunnel.xcodeproj` in Xcode
- Build both targets: **ZscalerSplitTunnel** (app) and **com.zscaler-split-tunnel.helper** (privileged helper)
- The app is a menu bar app (no dock icon) - look for the shield icon in the menu bar
- The helper requires SMJobBless installation for privileged route operations
- Build artifacts go to `macOS/build/` (gitignored)

## Architecture Notes

### macOS App
- **Menu bar app** using SwiftUI `MenuBarExtra` - no main window, lives in the system menu bar
- **Two-process model**: unprivileged SwiftUI app communicates with a root-privileged helper via XPC (`NSXPCConnection`)
- **XPC contract** defined in `Shared/XPCProtocol.swift` - both targets import Shared code
- **Helper runs as root** via SMJobBless/launchd to execute privileged `route` commands
- **Config files** stored in `~/.config/zscaler-split-tunnel/` (routes.conf, bypass.conf)
- **Observable state** via `@Observable AppState` pattern (Swift 5.9+)

### Broad Routes
Zscaler installs broad routes (e.g., `1/8`, `2/7`, `4/6`, `64/2`, `128/2`, `192/2` for IPv4) that capture nearly all traffic. The tool removes these and replaces them with specific routes for configured domains/IPs.

## Coding Style

### Bash (zscaler-split-tunnel.sh)
- POSIX-friendly Bash with `[[ ]]` and arrays where already used
- 4-space indent, upper snake case constants (`LOG_FILE`), lower snake case functions (`load_config`)
- Use existing `log`/`vlog` helpers, not raw echo

### Swift (macOS/)
- Swift 5.9+ with SwiftUI and `@Observable` macro
- Use `os.Logger` for logging (subsystem: bundle ID, category: class name)
- XPC reply callbacks use `@escaping` closures
- Helper operations go through `RouteEngine`/`ShellRunner` for shell commands
- Keep Shared/ types minimal - they must compile in both targets

## Testing
No automated tests. Validate manually:
- Shell: exercise add/remove flows, verify with `route get` and `--list`
- macOS app: verify XPC connection, route operations, config editor, network change detection
- Run `shellcheck` on the bash script before committing
- Include command transcripts or log excerpts in PRs when altering networking logic

## Configuration Files
- `~/.config/zscaler-split-tunnel/routes.conf` - domains/IPs to route through Zscaler (one per line, `#` comments)
- `~/.config/zscaler-split-tunnel/bypass.conf` - direct overrides routed outside Zscaler
- Legacy paths `~/.config/zscaler-split-tunnel.conf` and `~/.config/zscaler-bypass.conf` are auto-migrated
- Runtime state (`domain-cache.txt`, `remote-route-cache.txt`) lives alongside config

## Security Considerations
- The helper runs as root and executes `/sbin/route` - validate all inputs from XPC
- Never commit personal routes, credentials, or internal URLs
- Review permissions on installed binaries
- Test route changes on lab machines before production laptops
- The app sandbox is disabled (required for XPC to privileged helper and network operations)

## Commit & PR Guidelines
- Follow Conventional Commits (`feat(routing): add utun fallback`)
- Keep commits atomic and scoped to one logical change
- PRs should describe intent, risks, and manual verification steps
- Call out sudo-sensitive or route-modifying changes for extra scrutiny
