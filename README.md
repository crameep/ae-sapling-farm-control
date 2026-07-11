# AE Sapling Farm Control

ComputerCraft / CC:Tweaked touchscreen app for controlling an AE2-fed sapling farm through an Advanced Peripherals ME Bridge.

It scans AE2 for saplings, lets you select a sapling on a monitor, and keeps a farm input buffer topped up while the farm feed is enabled.

## Requirements

- CC:Tweaked
- Advanced Peripherals
- AE2 network
- Advanced Peripherals ME Bridge
- Advanced Computer
- Advanced Monitor, recommended
- Farm input buffer chest adjacent to the ME Bridge

## Install

Run this on the ComputerCraft computer:

```lua
wget run https://raw.githubusercontent.com/crameep/ae-sapling-farm-control/main/install.lua
```

Manual install:

```lua
delete startup.lua
wget https://raw.githubusercontent.com/crameep/ae-sapling-farm-control/main/startup.lua startup.lua
reboot
```

## Physical Layout

The export buffer must be next to the ME Bridge. The computer does not export items directly; it asks the bridge to export into one of the bridge's sides.

Example:

```text
AE2 Cable -> ME Bridge -> Farm Input Buffer Chest
              |
        Wired modem/network
              |
      Advanced Computer -> Monitor
```

If the buffer is above the ME Bridge, set export side to `up`. If it is north/east/south/west/down, use that side.

## First Run Setup

Tap `SETUP` or press `s` on the keyboard.

You will set:

- ME Bridge export side, default `up`
- optional farm input buffer peripheral name, used for exact buffer counting
- redstone side, default `back`
- target buffer amount, default `256`
- export batch size, default `64`

If you do not set a buffer peripheral name, the app still works, but it cannot know how many selected saplings are already in the buffer. It will export one batch every cycle while enabled.

## Controls

- `FARM ON/OFF`: toggles sapling feeding and redstone output
- `REFRESH`: rescans AE saplings
- `UPDATE`: downloads the latest `startup.lua` from this repo and reboots
- `SETUP`: re-run setup
- Tap any sapling row to select it
- `-64` / `+64`: adjust target buffer
- `B-16` / `B+16`: adjust export batch

Keyboard shortcuts:

- `space`: toggle farm feed
- `r`: refresh
- `u`: update
- `s`: setup
- `c`: trigger cleanup turtle

## Optional Cleanup Turtle

The `CLEAN` button can trigger a wireless turtle to remove stray dark oak saplings that are not part of a valid 2x2 dark oak cluster.

Install on a wireless turtle:

```lua
delete startup.lua
wget https://raw.githubusercontent.com/crameep/ae-sapling-farm-control/main/turtle.lua startup.lua
reboot
```

Place the turtle:

- one block above the first planting cell
- facing east
- at the northwest/start corner of the farm grid
- with a wireless modem attached
- with enough fuel for a full scan and return trip

On first boot, set the grid width/depth. The app and turtle default to the same Rednet protocol: `sapfarm`.

Behavior:

- maps every planting cell first
- detects `minecraft:dark_oak_sapling`
- keeps any sapling that belongs to a complete 2x2 dark oak cluster
- digs lone/misaligned dark oak saplings
- returns to the start position

Optional turtle command line:

```lua
clean
setup
exit
```

## SFM Pairing

Use SFM for farm logistics, not UI.

Example:

```sfm
every 20 ticks do
    if redstone > 0 then
        input with #minecraft:saplings from farm_input
        output to sower_buffer

        input from gatherer_output
        output to farm_output
    end
end
```

ComputerCraft controls which sapling gets exported into `farm_input`; SFM keeps moving it to the farm.

## Updating

Tap `UPDATE` in the app.

Manual update:

```lua
delete startup.lua
wget https://raw.githubusercontent.com/crameep/ae-sapling-farm-control/main/startup.lua startup.lua
reboot
```

## Local Files

The app creates:

- `.sapfarm_config`
- `.sapfarm_state`

These stay on the ComputerCraft computer and are not part of the repo.
