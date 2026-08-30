# SexyCastbar

Replaces the default player cast bar in WoW Classic Era with a **watch face**:
a metal ring with twelve tick marks, consumed clockwise as your cast
progresses, with the seconds remaining counting down in a smoked-glass center
over the spell's icon, and the spell name underneath.

Everything the standard cast bar would show — spells, Hearthstone, opening
quest items and chests, channels — shows here instead; the default bar is
disabled while the addon is loaded.

- **Gold ring** for casts, **teal ring** for channels.
- The countdown turns gold in the final quarter of the cast.
- **White blip** when a cast completes; **red flash** when it's interrupted
  or cancelled. Clipping a channel early just fades out quietly.
- The sweep edge line acts as the watch hand.
- Survives `/reload` and loading screens mid-cast.

## Commands

- `/scb` (or `/sexycastbar`) — unlock: the face appears and can be dragged;
  `/scb` again locks it. Position is saved.
- `/scb test` — play a fake 5-second cast to preview the look.

## Install

Drop the `SexyCastbar` folder into
`World of Warcraft/_classic_era_/Interface/AddOns/` and `/reload`.
Disable the addon to get the default cast bar back.
