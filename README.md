<img src="assets/icon.svg" width="64" height="64" alt="">

# Cua Driver for Droppy

A [Droppy](https://getdroppy.app) droplet for [cua-driver](https://github.com/trycua/cua). It shows when an agent is driving your Mac and gives you a button to stop it.

While an agent session is acting, a live activity next to the notch shows a cursor glyph and the session's name. If several sessions are acting, it shows a count instead, like `×2`.

The shelf widget lists every session the driver is running, with the client type, how long ago it last acted, and a Stop button for each one. The button in the widget's header stops all of them.

When no agent is connected, the widget shows whether cua-driver has Accessibility and Screen Recording access.

## How it works

The droplet talks to the cua-driver daemon over its local socket, `~/Library/Caches/cua-driver/cua-driver.sock`. Each request and response is one JSON object per line:

| What | Request |
| --- | --- |
| List sessions from every client | `{"method":"sessions_list"}` |
| Stop one session | `{"method":"revoke_authorization","args":{"session":"<label>"}}` |
| Stop every session | `{"method":"revoke_authorization","args":{"all":true}}` |
| Permissions | `{"method":"call","name":"check_permissions","args":{}}` |

A session counts as "driving" if it made a call in the last 15 seconds. The droplet checks every 2 seconds while an agent is driving, every 4 seconds when the daemon is idle, and every 10 seconds when the daemon isn't running. All socket I/O runs on a background queue with a 1.5-second timeout.

Stopping a session revokes it. It can't grant access to anything. The daemon keeps listing a revoked session as `active` until it expires, so the droplet hides any session it has stopped until that session makes a call again.

The protocol isn't documented, so I worked it out from cua-driver 0.38.0. A future driver release could change it.

## Requirements

- cua-driver running (`cua-driver serve`, or the CuaDriver app)
- Droppy 15.3.0 or later

## Developing

Set up the DroppyKit SDK first ([Add the package](https://getdroppy.app/docs/droppykit/add-spm)), then:

```bash
droppykit run        # the harness, with live data from your daemon
droppykit build      # .build/Cuadriver.droplet
droppykit validate   # the Store's checks
droppykit run -- --shots ./shots --report ./shots/report.json
```

To try it in Droppy Playground, copy `.build/Cuadriver.droplet` to `~/Library/Application Support/Droppy Playground/Droplets/cuadriver/` and relaunch the Playground. In Droppy itself, add it under Settings › Store › Local droplets.

## Before submitting to the Store

- `Cuadriver.icon` is a placeholder, and the Droppy team designs Store icons. Icon idea: the `cursorarrow.rays` SF Symbol.
- Replace `Assets/Creator.png` with your own avatar.
- The droplet connects to a local Unix socket that belongs to another app. No DroppyKit capability covers that, so ask the Droppy team about it in the merge request.
