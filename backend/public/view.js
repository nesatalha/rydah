const params = new URLSearchParams(location.hash.slice(1));
const id = params.get('id'), token = params.get('token');
history.replaceState(null, '', location.pathname);
const el = id => document.getElementById(id);
let data = null, terminal = null, connection = '', polling = false;
let map = null, marker = null, trailLayer = null;
// Cached trail: [seq, lat, lon, observedAt] tuples. Later polls request only points after maxSeq.
let trailPoints = [], trailSetting = null, maxSeq = 0, trailVersion = 0, trailKey = '';
const trailLabels = { '15m': 'Recent path: last 15 minutes', '30m': 'Recent path: last 30 minutes', session: 'Recent path: whole session' };
function clearTrail() {
    trailPoints = [];
    trailSetting = null;
    maxSeq = 0;
    trailVersion++;
}
function mergeTrail(trail) {
    if (!trail) {
        if (trailSetting || trailPoints.length) {
            clearTrail();
        }
        return;
    }
    if (trail.reset) {
        trailPoints = [];
        maxSeq = 0;
    }
    for (const point of trail.points) {
        if (point[0] > maxSeq) {
            trailPoints.push(point);
            maxSeq = point[0];
        }
    }
    if (trail.windowStartsAt !== null) {
        trailPoints = trailPoints.filter(point => point[3] >= trail.windowStartsAt);
    }
    trailSetting = trail.setting;
    trailVersion++;
}
const fade = [0.85, 0.6, 0.4, 0.22];
// Splits at gaps over a minute, then into age buckets; neighbouring segments share their boundary point.
function renderTrail(now, point) {
    if (!trailLayer) {
        return;
    }
    const key = `${trailVersion}/${Math.floor(now / 5000)}/${point.observedAt}`;
    if (key === trailKey) {
        return;
    }
    trailKey = key;
    trailLayer.clearLayers();
    const path = trailPoints.map(p => ({ position: [p[1], p[2]], at: p[3] }));
    if (path.length && point.observedAt > path[path.length - 1].at) {
        path.push({ position: [point.lat, point.lon], at: point.observedAt });
    }
    if (path.length < 2) {
        return;
    }
    const span = Math.max(trailSetting === '15m' ? 900000 : trailSetting === '30m' ? 1800000 : now - path[0].at, 1);
    const bucket = at => Math.min(fade.length - 1, Math.max(0, Math.floor((now - at) / span * fade.length)));
    let segment = [path[0]];
    const flush = () => {
        if (segment.length > 1) {
            trailLayer.addLayer(L.polyline(segment.map(p => p.position), {
                color: '#0f766e', weight: 4, opacity: fade[bucket(segment[segment.length - 1].at)], interactive: false
            }));
        }
    };
    for (let i = 1; i < path.length; i++) {
        const previous = path[i - 1], current = path[i];
        if (current.at - previous.at > 60000) {
            flush();
            segment = [current];
        }
        else if (bucket(current.at) !== bucket(previous.at)) {
            segment.push(current);
            flush();
            segment = [current];
        }
        else {
            segment.push(current);
        }
    }
    flush();
}
let photoUrl = null, photoVersion = null, photoGeneration = 0, iconKey = null, photoRetryAt = 0;
function clearPhoto() {
    photoGeneration++;
    if (photoUrl) {
        URL.revokeObjectURL(photoUrl);
    }
    photoUrl = null;
    photoVersion = null;
    iconKey = null;
    photoRetryAt = 0;
}
function avatarIcon() {
    const node = document.createElement('div');
    node.className = 'rider-avatar';
    if (photoUrl) {
        const image = document.createElement('img');
        image.src = photoUrl;
        image.alt = '';
        image.addEventListener?.('error', () => {
            if (photoUrl === image.src) {
                URL.revokeObjectURL(photoUrl);
                photoUrl = null;
                iconKey = null;
                render();
            }
        });
        node.appendChild(image);
    }
    else {
        const name = data?.sender?.name || 'Rider';
        node.textContent = name.trim().split(/\s+/).slice(0, 2).map(word => Array.from(word)[0] || '').join('').toUpperCase();
    }
    return L.divIcon({
        html: node, className: 'rider-marker', iconSize: [48, 48], iconAnchor: [24, 24]
    });
}
function updateMarkerIcon() {
    if (!marker) {
        return;
    }
    const key = `${data?.sender?.name || ''}/${photoUrl || ''}`;
    if (key !== iconKey) {
        marker.setIcon(avatarIcon());
        iconKey = key;
    }
}
async function loadPhoto() {
    const version = data?.sender?.avatarVersion || 0;
    if (!version || terminal) {
        if (photoVersion !== null || photoUrl) {
            clearPhoto();
        }
        return;
    }
    if (photoVersion === version || Date.now() < photoRetryAt) {
        return;
    }
    clearPhoto();
    photoVersion = version;
    const generation = photoGeneration;
    try {
        const response = await fetch(`/api/sessions/${encodeURIComponent(id)}/avatar`, {
            headers: { Authorization: `Bearer ${token}` }, cache: 'no-store', signal: AbortSignal.timeout(8000)
        });
        if (!response.ok) {
            if (response.status >= 500 || response.status === 429) {
                throw Error('photo unavailable');
            }
            return;
        }
        const blob = await response.blob();
        if (terminal || generation !== photoGeneration || Date.now() >= data.expiresAt) {
            return;
        }
        photoUrl = URL.createObjectURL(blob);
        iconKey = null;
        updateMarkerIcon();
    }
    catch {
        if (generation === photoGeneration) {
            photoVersion = null;
            photoRetryAt = Date.now() + 5000;
        }
    }
}
const defaultZoom = 16;
el('recenter').addEventListener('click', () => {
    if (map && !terminal && data?.location && Date.now() < data.expiresAt) {
        map.setView([data.location.lat, data.location.lon], defaultZoom);
    }
});
const labels = {
    waiting: 'Waiting for GPS', live: 'Live location', stale: 'Last known location', offline: 'No recent updates', ended: 'Sharing ended', expired: 'Link expired', invalid: 'Link unavailable'
};
function render() {
    let state = terminal || data?.state || 'waiting';
    const now = Date.now();
    if (data && now >= data.expiresAt) {
        terminal = 'expired';
        state = 'expired';
        data.location = null;
    }
    if (terminal) {
        clearPhoto();
        if (trailSetting || trailPoints.length) {
            clearTrail();
        }
    }
    el('trail').hidden = !!terminal || !trailSetting;
    el('trail').textContent = terminal ? '' : trailLabels[trailSetting] || '';
    el('sender-name').textContent = terminal ? '' : data?.sender?.name || '';
    if (!terminal) {
        loadPhoto();
    }
    const point = terminal ? null : data?.location;
    if (point && !['ended', 'expired'].includes(state)) {
        const age = Math.max(0, now - point.observedAt);
        state = age <= 20000 ? 'live' : age <= 60000 ? 'stale' : 'offline';
    }
    el('status').className = `status ${state}`;
    el('status').textContent = labels[state] || state;
    el('source').textContent = data?.source === 'simulation' ? 'SIMULATION — NOT PHONE GPS' : data?.source === 'device' ? 'DEVICE GPS • ANDROID' : '';
    el('connection').textContent = connection;
    el('coords').textContent = point ? `${point.lat.toFixed(5)}, ${point.lon.toFixed(5)}` : 'No shared position';
    el('accuracy').textContent = point ? `Accuracy ±${Math.round(point.accuracyM)} m` : 'Accuracy —';
    el('captured').textContent = point ? `Captured ${new Date(point.observedAt).toLocaleTimeString()}` : 'Captured —';
    el('age').textContent = point ? `Age ${Math.max(0, Math.floor((now - point.observedAt) / 1000))} seconds` : 'Age —';
    el('message').textContent = ({
        waiting: 'The sender has not uploaded a location yet.', live: 'A recently captured point from this ride.', stale: 'This point is aging. Waiting for a newer update.', offline: 'The last point is over a minute old.', ended: 'The sender stopped sharing. Coordinates have been removed.', expired: 'This private session has expired. Start a new share for a fresh link.', invalid: 'Open the full private link supplied by the sender.'
    })[state];
    el('map').hidden = !point;
    el('placeholder').hidden = !!point;
    el('external').hidden = !point;
    el('recenter').hidden = !point;
    if (point) {
        const position = [point.lat, point.lon];
        if (!map) {
            map = L.map('map').setView(position, defaultZoom);
            L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
                maxZoom: 19, referrerPolicy: 'origin',
                attribution: '&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noreferrer">OpenStreetMap contributors</a>',
            }).addTo(map);
            trailLayer = L.layerGroup().addTo(map);
            trailKey = '';
            marker = L.marker(position, { icon: avatarIcon() }).addTo(map);
            iconKey = null;
        }
        else {
            marker.setLatLng(position);
        }
        updateMarkerIcon();
        renderTrail(now, point);
        el('external').href = `https://www.openstreetmap.org/?mlat=${point.lat}&mlon=${point.lon}#map=16/${point.lat}/${point.lon}`;
    }
    else {
        if (map) {
            map.remove();
            map = null;
            marker = null;
            trailLayer = null;
        }
        el('external').removeAttribute('href');
    }
}
async function poll() {
    if (polling || terminal) {
        return;
    }
    polling = true;
    try {
        const response = await fetch(`/api/sessions/${encodeURIComponent(id)}${maxSeq > 0 ? `?since=${maxSeq}` : ''}`, {
            headers: { Authorization: `Bearer ${token}` }, cache: 'no-store', signal: AbortSignal.timeout(8000)
        });
        if (response.status === 410) {
            terminal = 'expired';
            data = null;
        }
        else if (response.status === 401) {
            terminal = 'invalid';
            data = null;
        }
        else if (!response.ok) {
            throw Error('server unavailable');
        }
        else {
            data = await response.json();
            mergeTrail(data.trail);
            connection = '';
            if (data.state === 'ended') {
                terminal = 'ended';
            }
        }
    }
    catch {
        connection = 'Connection interrupted. Retrying; displayed age continues to increase.';
    }
    finally {
        polling = false;
        render();
    }
}
if (!id || !token) {
    terminal = 'invalid';
    render();
}
else {
    poll();
    setInterval(poll, 5000);
    setInterval(render, 1000);
}
