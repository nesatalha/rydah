# Viewer map recenter

> **Status:** Implemented in 33e1864.

**Goal:** Preserve the browser viewer's pan and zoom across live GPS updates, with a small manual recenter button.

**Cause:** `view.js` replaces the OpenStreetMap iframe URL whenever coordinates change, reloading the map and discarding its viewport.

**Design:** Use one Leaflet 1.9.4 map with OpenStreetMap tiles and a moving circle marker. Center at zoom 16 on the first position only. A compact “Recenter” button returns to the latest position at zoom 16. Keep polling and freshness indicators unchanged. Hide the button and destroy the map when coordinates are cleared or sharing ends/expires. Vendor the pinned library and its license locally. Send only the site origin as the tile referrer.

Keeping the iframe and refreshing only on click would leave the map marker stale. A persistent map preserves both live position updates and the user's viewport.

**Implementation:**
1. Add viewer regression tests reproducing viewport resets and covering manual recenter, waiting, network errors and terminal cleanup.
2. Replace the iframe with a map container and accessible corner button; update the marker without moving the viewport.
3. Run viewer/API tests and typecheck; verify desktop/mobile layout and interactions in a browser where available.
