# Zscaler Split Tunnel for macOS

A powerful tool to enable split tunneling with Zscaler on macOS, allowing you to route specific domains and IP addresses through Zscaler while the rest of your traffic goes directly to the internet.

Includes both a **shell script daemon** and a native **macOS menu bar app** with a privileged helper.

## Features

- **Automatic Route Management**: Continuously removes Zscaler's broad routes that capture all internet traffic
- **Zscaler Route Configuration**: Route specific domains, IPs, or CIDR ranges through Zscaler
- **Direct Override Configuration**: Force specific routes to use the direct network gateway when Zscaler has a more-specific route
- **Automatic Config Reload**: Applies configuration changes immediately while the daemon runs on a low-frequency cadence
- **Smart Zscaler Management**: Only starts Zscaler if not already running
- **Domain Resolution**: Automatically resolves domains to IP addresses with caching
- **Daemon Mode**: Runs in the background to maintain split tunnel configuration
- **Autostart Support**: Optional launchd job keeps the daemon running after reboots
- **Office WiFi Routing**: When connected to a corporate switch (detected via CDP/LLDP), routes direct override traffic through a guest WiFi interface
- **Native macOS App**: SwiftUI menu bar app with real-time status, route counters, and a privileged helper daemon

## Quick Install

```bash
# Clone the repository
git clone https://github.com/balcsida/zscaler-split-tunnel.git && cd zscaler-split-tunnel

# Install and start
chmod +x zscaler-split-tunnel.sh && \
sudo mkdir -p /usr/local/bin && \
sudo cp zscaler-split-tunnel.sh /usr/local/bin/zscaler-split-tunnel && \
sudo chmod +x /usr/local/bin/zscaler-split-tunnel && \
sudo zscaler-split-tunnel --start
```

## Usage

### Basic Commands

```bash
# Start split tunneling (starts Zscaler if needed)
sudo zscaler-split-tunnel --start

# Stop split tunneling daemon
sudo zscaler-split-tunnel --stop

# Completely kill Zscaler app and services
sudo zscaler-split-tunnel --kill

# Check status
zscaler-split-tunnel --status

# Show all routes
zscaler-split-tunnel --list
```

### Configuration Management

```bash
# Add domain/IP/CIDR to route through Zscaler
zscaler-split-tunnel --add example.com
zscaler-split-tunnel --add 192.168.1.0/24
zscaler-split-tunnel --add 10.0.0.5

# Remove entry from configuration
zscaler-split-tunnel --remove example.com

# Show current configuration
zscaler-split-tunnel --show-config

# Clear all Zscaler routes
zscaler-split-tunnel --clear-config
```

### Advanced Options

```bash
# Start with custom check interval (default: 300 seconds)
sudo zscaler-split-tunnel --start --interval 5

# Enable verbose logging
sudo zscaler-split-tunnel --start --verbose

# Run daemon directly (for debugging)
sudo zscaler-split-tunnel --daemon --verbose
```

### Autostart on Boot

Install a launchd service so the daemon starts automatically after reboots:

```bash
sudo zscaler-split-tunnel --enable-autostart
```

Remove it later with:

```bash
sudo zscaler-split-tunnel --disable-autostart
```

## Configuration Files

Defaults are versioned in this repository so the whole team shares the same baseline:

- `config/zscaler-split-tunnel.conf` – Zscaler routes forced through the tunnel
- `config/zscaler-bypass.conf` – direct overrides that should skip Zscaler

User-specific overrides live under `~/.config/zscaler-split-tunnel/`:

- `~/.config/zscaler-split-tunnel/routes.conf`
- `~/.config/zscaler-split-tunnel/bypass.conf`

The `--add` and `--add-bypass` commands append to the user files, keeping defaults untouched.
Example overrides file:

```bash
# Example overrides
internal.company.com
vpn.company.com
192.168.100.0/24
10.0.0.50
```

Changes are written to disk immediately and the running daemon reloads the new configuration right away.

### Office WiFi Routing

When your Mac is connected to Ethernet at the office (detected via CDP/LLDP discovery packets from corporate switches) and a guest WiFi network is available, direct overrides can be automatically routed through the WiFi gateway instead of the default Ethernet gateway.

Create `~/.config/zscaler-split-tunnel/office-mode.json`:

```json
{
  "enabled": true,
  "targetSSID": "Guest_WiFi",
  "cdpGracePeriodSeconds": 120,
  "switchNamePatterns": []
}
```

## macOS Menu Bar App

The `macOS/` directory contains a native SwiftUI menu bar application with:

- Real-time status display (Zscaler interface, monitoring state, route counts)
- Start/stop monitoring, refresh routes
- Start/kill Zscaler
- DNS cache flushing
- Office mode status display
- Settings window for Zscaler routes and direct overrides

Build with Xcode 16+ or [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
cd macOS
xcodegen generate
open ZscalerSplitTunnel.xcodeproj
```

## How It Works

1. **Broad Route Removal**: Removes Zscaler's broad routes (like 1.0.0.0/8, 2.0.0.0/7, etc.) that capture most internet traffic
2. **Zscaler Routes**: Adds specific routes for your configured domains/IPs through the Zscaler interface (typically utun8)
3. **Continuous Monitoring**: Runs as a daemon on a low-frequency (5 minute) interval to keep routes tidy without burning CPU
4. **Automatic Updates**: Signals the daemon to reload instantly whenever configuration files change

## Files and Logs

- **Default configs**: `config/zscaler-split-tunnel.conf`, `config/zscaler-bypass.conf`
- **User overrides**: `~/.config/zscaler-split-tunnel/routes.conf`, `~/.config/zscaler-split-tunnel/bypass.conf`
- **Log File**: `/tmp/zscaler-split-tunnel.log`
- **PID File**: `/tmp/zscaler-split-tunnel.pid`
- **Domain Cache**: `/tmp/zscaler-domain-cache.txt`
- **LaunchDaemon (optional autostart)**: `/Library/LaunchDaemons/com.github.zscaler-split-tunnel.plist`

## Troubleshooting

### Check if split tunneling is active
```bash
zscaler-split-tunnel --status
```

### View detailed routes
```bash
zscaler-split-tunnel --list
```

### Check logs
```bash
tail -f /tmp/zscaler-split-tunnel.log
```

### Verify a domain is routed through Zscaler
```bash
# Check route for a specific IP
route get $(dig +short example.com | head -1)
```

### If a site isn't loading
1. Check DNS resolution: `dig +short yourdomain.com`
2. Verify the route: `netstat -rn | grep <ip-address>`
3. Test connectivity: `curl -I https://yourdomain.com`

## Common Use Cases

### Corporate Resources
Route internal corporate resources through Zscaler while keeping personal traffic direct:
```bash
zscaler-split-tunnel --add internal.company.com
zscaler-split-tunnel --add jira.company.com
zscaler-split-tunnel --add gitlab.company.com
```

## Requirements

- macOS (tested on macOS 15.5)
- Zscaler client installed
- Administrator privileges (for route management)
- Standard macOS command line tools (netstat, route, dig, curl)

## License

MIT
