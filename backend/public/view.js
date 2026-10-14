const params = new URLSearchParams(location.hash.slice(1));
const id = params.get('id'), token = params.get('token');
history.replaceState(null, '', location.pathname);
const el = id => document.getElementById(id);
let data = null, terminal = null, connection = '', polling = false;
let map = null, marker = null;
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
    }
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
            marker = L.marker(position, { icon: avatarIcon() }).addTo(map);
            iconKey = null;
        }
        else {
            marker.setLatLng(position);
        }
        updateMarkerIcon();
        el('external').href = `https://www.openstreetmap.org/?mlat=${point.lat}&mlon=${point.lon}#map=16/${point.lat}/${point.lon}`;
    }
    else {
        if (map) {
            map.remove();
            map = null;
            marker = null;
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
        const response = await fetch(`/api/sessions/${encodeURIComponent(id)}`, {
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
