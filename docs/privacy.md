# Privacy and storage

## Session secrets and viewer links

Each session has independent random 256-bit read/write secrets. D1 stores only their SHA-256 hashes. Viewer links put the read secret in a URL fragment, parse it into memory, and immediately remove the fragment from browser history. Invitation pages do the same with invitation tokens. API responses are not cached. Do not share the full private link beyond your intended viewers.

Device credentials are persisted in Android secure storage on the phone, scoped to the backend URL and excluded from backup; see [mobile.md](mobile.md#identity-and-recovery).

## What the server keeps

By default, one current point per session is retained and there is no route history. Stopping clears its coordinates. The current point includes the phone's GPS speed and speed accuracy when available; they are visible through the private link and, for group shares, to current members, and are cleared with the coordinates on stop, removal, leaving and group deletion (trail points never include speed).

A trail is opt-in per share and off by default. With it on, the server also keeps recent points, thinned to one per 10 seconds, only within the chosen window (15 minutes, 30 minutes, or the whole session). They are visible only through the private link and, for group shares, to current group members. Stop, member removal, leaving and group deletion delete them immediately; after expiry they are unreadable and are removed with the session by the hourly cleanup. Device sessions expire after their chosen 30, 60, 120 or 240 minutes; the legacy creator/simulator route still uses one hour. Reads and writes after expiry return 410 without coordinates.

The hourly scheduled cleanup deletes expired session rows, retaining a last point for at most roughly one hour beyond its expiry when the deployed schedule runs. Used session IDs remain as location-free replay protection; a sweep also removes any trail point whose session is no longer active. Consumed invitations keep only their hashed enrollment receipt. Profile photos are stored privately in D1 and served only through authenticated endpoints.

Local development does not automatically run cron. To manually delete expired local rows (their trail points are deleted with them):

```bash
cd backend
npx wrangler d1 execute rydah --local --command "DELETE FROM sessions WHERE expires_at <= CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)"
```

## Third parties

OpenStreetMap receives the viewed map area; private API credentials are not sent to it. External Google Fonts loads the interface font. Both pages use `Referrer-Policy: no-referrer`; map tile requests override this to send only the site origin for OpenStreetMap attribution of requests. Leaflet 1.9.4 is served locally from `backend/public/vendor/leaflet`.

## Transport

Local HTTP is only for development; debug Android builds permit cleartext networking. A shared public backend requires HTTPS and a private creator secret that differs from the local demo key.
