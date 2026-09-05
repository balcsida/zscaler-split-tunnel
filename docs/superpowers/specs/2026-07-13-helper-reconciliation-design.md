# Helper Reconciliation Design

## Goal

Keep Zscaler split tunneling responsive across network changes without running the full route and DNS reconciliation every 30 seconds.

## Evidence

- Headroom failed during the office-to-home transition because its local proxy could not resolve `chatgpt.com`.
- A privileged stack sample caught `HelperTool.getStatus` synchronously waiting for `pgrep`, `netstat`, and `route` subprocesses.
- Zscaler restored all 15 broad routes five times without any network-change event. Periodic reconciliation therefore remains necessary.

## Design

### Reconciliation cadence

Retain the existing 30-second monitor timer, but split its work:

- Every 30 seconds: remove Zscaler broad routes, repair default-route health, detect network/config/gateway/interface changes, and update office state.
- Every five minutes: reload DNS and remote route sources and reconcile the full custom and bypass route sets.
- Immediately reconcile the full route sets on helper startup, network changes, config changes, bypass-gateway changes, and manual refresh.
- Retain the four six-second follow-up broad-route sweeps after a network change because Zscaler can reconnect after the first sweep.

The five-minute full-refresh interval matches the existing DNS cache freshness window. No new watcher, scheduler, or dependency is needed.

### Status path

`getStatus` returns the latest completed status snapshot immediately. Each request also schedules a coalesced background refresh of live fields such as Zscaler process state, detected tunnel interface, broad-route counts, and network signature. The next poll observes the refreshed values, so status can be up to one five-second UI poll old but cannot block the XPC reply path.

Monitor-owned fields continue to come from `MonitorLoop.StatusSnapshot`. The first status request after helper launch may contain defaults while the initial live refresh runs; the next poll supplies live values and preserves the existing monitoring auto-start behavior.

### Subprocess deadlines

All `ShellRunner` entry points gain a bounded execution time. On timeout, the helper terminates the exact child process, escalates to a forced kill if necessary, drains its pipes, and returns a distinct timeout exit status. Status probes use a short deadline that fits within the app's five-second XPC budget; longer recovery commands retain a larger bounded deadline.

This fixes the shared failure boundary once instead of adding timeouts to individual callers.

## Error handling

- A timed-out status probe preserves the previous snapshot value and logs the failed command.
- A timed-out route or recovery command returns failure to its existing caller instead of wedging the helper.
- Background status refreshes are coalesced so five-second UI polling cannot create a work backlog.
- Reinstall remains unchanged; once helper subprocesses are bounded, ServiceManagement no longer has to replace a process stuck forever in a child command.

## Testing

- Add a focused scheduling test proving full reconciliation runs on startup, after five minutes, and when forced, but not on ordinary 30-second sweeps.
- Add `ShellRunner` tests proving normal output still works and sleeping commands time out for each public runner method.
- Run both macOS unit-test schemes and build the app and helper targets.
- Verify live XPC status remains responsive while the monitor is reconciling routes, then confirm the 30-second log cadence removes spontaneously restored broad routes while full route reloads occur only at the five-minute cadence.

## Non-goals

- Removing periodic reconciliation entirely.
- Adding PF_ROUTE listeners or helper-side filesystem watchers.
- Changing route contents, DNS retention, office detection, or Headroom configuration.
