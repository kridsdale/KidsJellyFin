# Queued engineering goals

## Next: automatic LAN server discovery — requested 2026-10-17

Status: queued after the active Parents integration and acceptance goal. This is
the human-authorized next goal; it does not replace or complete the active goal.

Both the Parents iPhone app and the Kids tvOS app should automatically find their
server on the home LAN. Normal setup should not require typing a hostname, DNS
name or IP address. Include discovery of the matching Parents control service so
the phone's administrative connection is covered as well as its Jellyfin login.

Acceptance scope:

- Discover available Jellyfin servers and the associated Parents control service
  using supported LAN discovery mechanisms, with the necessary platform local
  network permission descriptions and entitlements.
- Provide a simple server chooser when more than one server is found and clear
  states for searching, no results, denied permission and an unavailable server.
  Retain manual entry as a recovery option.
- Preserve the selected server's identity, existing accounts, approved library
  boundaries and credential/origin checks. Discovery alone must not authenticate,
  broaden library access, start playback or change server configuration.
- Rediscover a previously selected server after an address change or network
  interruption without silently switching to a different server.
- Cover parsing, selection, identity validation, stale results and reconnect
  behavior with focused tests. Separately record observed LAN discovery on each
  available platform; simulator/build evidence is not physical-device evidence.

At the start of this goal, inspect existing client/server discovery support and
choose the smallest shared implementation that fits the package architecture.
Any required backend advertising work should be coordinated with the server
agent. No discovery probes or server changes are initiated by this queue entry.
