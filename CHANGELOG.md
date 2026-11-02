# Changelog

## [1.1.0] - 2026-11-02

- A keyboard shortcut stops every agent from any app, even with the shelf closed: ⌃⌥⌘⎋, unless something else already uses it. You can change it on Droppy's Shortcuts page, and a card on the notch tells you how many agents it stopped.
- When an agent starts driving your Mac, a card drops out of the notch with its name. Agents that were already running when Droppy started, or while the Mac slept, don't get one. You can turn it off in Settings.
- Cua Driver has a page in Settings now. It shows whether the driver is running, its version, its permission mode, and whether it has Accessibility and Screen Recording, with the command to fix any that are missing. It also lets you turn off the notch or the card, and choose how long a paused agent still counts as driving.
- An agent that pauses to think no longer makes the notch flicker. It counts as driving for 30 seconds after its last action, which you can set from 15 seconds to 2 minutes.
- The notch shows a record mark while the agent that's driving records the screen, and a longer name such as `claude-code` shows as `claude` instead of `Agent`.
- Each session's row says when it started and whether it's recording, and rows stay in place instead of reordering as agents act. The widget is as tall as the rows it shows.
- The widget warns you when the driver runs in unrestricted mode, where agents act without asking.
- Stop every agent says what it really does: cua-driver blocks new agents until it restarts. While that lasts, the widget says agents are blocked and Settings shows the command to restart the driver. Before, the widget mistook it for missing permissions.
- Scripts and Shortcuts can stop every agent by opening `droppy://droplet/cuadriver/stop`.
- The widget notices the driver starting or stopping within a moment, and catches up as soon as the Mac wakes.

## [1.0.0] - 2026-11-01

- A live activity in the notch while a cua-driver agent session is acting.
- A shelf widget that lists sessions, with Stop for each session and for all of them.
- Shows cua-driver's Accessibility and Screen Recording status when no agent is connected.
