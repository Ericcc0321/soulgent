Flame sprite strip under the conversation avatar (Blaze Mode)

Source: flame assets made together with this project, exported as sprite sheets.
Content: only fire and ground glow, transparent background, already composited the way the board does it -- overlay with normal blending directly under the avatar image; no blend mode, no opacity change.

Files (frames left to right):
  busy.png     1152x120  12 frames, each 96x120   strong (conversation busy)
  busy@2x.png  2304x240  12 frames, each 192x240
  idle.png      576x120   6 frames, each 96x120   weak (all other states)
  idle@2x.png  1152x240   6 frames, each 192x240

Placement (1x frame coordinates): character feet at x=48, y=112 (8 above the bottom edge), horizontally centered; character height 48, top of head at y=64.
Scale = actual character height / 48, scaling about the feet point.
Flame crown: busy rises about 0.42 of body height above the head (when it surges, the whole flame stretches 1.25x up from the feet, roughly frames 01-08), idle about 0.25.
Timing: busy 90ms per frame (1.08s); it is not a seamless loop, so it plays 00->11->00 back and forth (animation-direction: alternate) to hide the seam;
      idle 500ms per frame (3s) loop.

Usage: see the "Blaze Mode flame (sprite sheet)" block in web/style.css.
Serving: static via caddy (/srv/fx/fire/), behind the gate (needs the login cookie), not in the sw shell cache.
