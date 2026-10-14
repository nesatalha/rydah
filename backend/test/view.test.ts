import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createContext, runInContext } from 'node:vm';
const source = await readFile(new URL('../public/view.js', import.meta.url), 'utf8');
async function viewer(initialLocation: any = {
    lat: 41, lon: 29, accuracyM: 8
}, sender: any = null, photoStatus = 200) {
    let now = Date.now();
    let response: any = {
        state: initialLocation ? 'live' : 'waiting', source: 'device', expiresAt: now + 3600000,
        location: initialLocation && { ...initialLocation, observedAt: now }, sender,
    };
    let httpStatus = 200;
    let networkError = false;
    const elements = new Map<string, any>();
    const element = (id: string) => {
        if (!elements.has(id)) {
            elements.set(id, {
                hidden: true, textContent: '', listeners: new Map(),
                addEventListener(event: string, handler: () => void) {
                    this.listeners.set(event, handler);
                },
                removeAttribute(name: string) {
                    delete (this as any)[name];
                },
            });
        }
        return elements.get(id);
    };
    const requests: any[] = [], revoked: string[] = [], blobs: string[] = [];
    const makeNode = (tag: string) => ({
        tag, textContent: '', className: '', listeners: new Map(), addEventListener(event: string, handler: any) {
            this.listeners.set(event, handler);
        }, children: [] as any[], appendChild(child: any) {
            this.children.push(child);
        }, setAttribute(name: string, value: string) {
            (this as any)[name] = value;
        }
    });
    const maps: any[] = [];
    const markers: any[] = [];
    const context = createContext({
        URLSearchParams, URL: { createObjectURL() {
                const url = `blob:photo-${blobs.length}`;
                blobs.push(url);
                return url;
            }, revokeObjectURL(url: string) {
                revoked.push(url);
            } }, AbortSignal, location: { hash: '#id=test&token=secret', pathname: '/view.html' },
        history: { replaceState() {
            } }, document: { getElementById: element, createElement: makeNode }, setInterval() {
        },
        Date: class extends Date {
            static now() {
                return now;
            }
        },
        fetch: async (url: string, options: any) => {
            requests.push({ url, options });
            if (url.endsWith('/avatar')) {
                return {
                    status: photoStatus, ok: photoStatus === 200, blob: async () => ({ type: 'image/png' })
                };
            }
            if (networkError) {
                throw new Error('offline');
            }
            return {
                status: httpStatus, ok: httpStatus === 200, json: async () => structuredClone(response)
            };
        },
        L: {
            map() {
                const map = {
                    center: [], zoom: 0, removed: false,
                    setView(center: number[], zoom: number) {
                        this.center = Array.from(center);
                        this.zoom = zoom;
                        return this;
                    },
                    remove() {
                        this.removed = true;
                    },
                };
                maps.push(map);
                return map;
            },
            tileLayer() {
                return { addTo() {
                    } };
            },
            divIcon(options: any) {
                return options;
            },
            marker(position: number[], options: any) {
                const marker = {
                    position: Array.from(position), icon: options.icon, addTo() {
                        return this;
                    }, setLatLng(position: number[]) {
                        this.position = Array.from(position);
                        return this;
                    }, setIcon(icon: any) {
                        this.icon = icon;
                        return this;
                    }
                };
                markers.push(marker);
                return marker;
            },
            circleMarker(position: number[]) {
                const marker = {
                    position: Array.from(position),
                    addTo() {
                        return this;
                    },
                    setLatLng(position: number[]) {
                        this.position = Array.from(position);
                        return this;
                    },
                };
                markers.push(marker);
                return marker;
            },
        },
    });
    runInContext(source, context);
    await new Promise(resolve => setImmediate(resolve));
    return {
        element, maps, markers, requests, revoked, blobs,
        photoStatus(status: number) {
            photoStatus = status;
        },
        async identity(sender: any) {
            response.sender = sender;
            await runInContext('poll()', context);
            await new Promise(resolve => setImmediate(resolve));
        },
        async update(location: any) {
            response.location = location && {
                ...location, accuracyM: 8, observedAt: now
            };
            await runInContext('poll()', context);
        },
        async end(state: string, status = 200) {
            response.state = state;
            response.location = null;
            httpStatus = status;
            await runInContext('poll()', context);
        },
        async disconnect() {
            networkError = true;
            await runInContext('poll()', context);
        },
        advance(ms: number) {
            now += ms;
            runInContext('render()', context);
        },
        recenter() {
            element('recenter').listeners.get('click')();
        },
    };
}
test('live updates move the marker while preserving the viewer pan and zoom', async () => {
    const v = await viewer();
    assert.equal(v.maps.length, 1);
    assert.deepEqual(v.maps[0].center, [41, 29]);
    v.maps[0].setView([40, 28], 12);
    await v.update({ lat: 41.01, lon: 29.02 });
    v.advance(1000);
    assert.equal(v.maps.length, 1);
    assert.deepEqual(v.maps[0].center, [40, 28]);
    assert.equal(v.maps[0].zoom, 12);
    assert.deepEqual(v.markers[0].position, [41.01, 29.02]);
    assert.equal(v.element('coords').textContent, '41.01000, 29.02000');
});
test('manual recenter uses the latest point, restores zoom, then leaves subsequent updates alone', async () => {
    const v = await viewer();
    assert.equal(v.element('recenter').hidden, false);
    await v.update({ lat: 42, lon: 30 });
    v.recenter();
    assert.deepEqual(v.maps[0].center, [42, 30]);
    assert.equal(v.maps[0].zoom, 16);
    await v.update({ lat: 43, lon: 31 });
    assert.deepEqual(v.maps[0].center, [42, 30]);
    assert.deepEqual(v.markers[0].position, [43, 31]);
});
test('waiting hides recenter until the first point arrives', async () => {
    const v = await viewer(null);
    assert.equal(v.maps.length, 0);
    assert.equal(v.element('recenter').hidden, true);
    await v.update({ lat: 41, lon: 29 });
    assert.equal(v.maps.length, 1);
    assert.equal(v.element('recenter').hidden, false);
});
test('connection failures and aging preserve the viewport and last marker', async () => {
    const v = await viewer();
    assert.equal(v.maps.length, 1);
    v.maps[0].setView([40, 28], 12);
    await v.disconnect();
    v.advance(70000);
    assert.deepEqual(v.maps[0].center, [40, 28]);
    assert.equal(v.maps[0].zoom, 12);
    assert.equal(v.element('status').textContent, 'No recent updates');
    assert.match(v.element('connection').textContent, /Connection interrupted/);
});
for (const [state, status] of [['ended', 200], ['expired', 410], ['invalid', 401]] as const) {
    test(`${state} removes the map and recenter control`, async () => {
        const v = await viewer();
        assert.equal(v.maps.length, 1);
        await v.end(state, status);
        assert.equal(v.maps[0].removed, true);
        assert.equal(v.element('recenter').hidden, true);
        assert.equal(v.element('map').hidden, true);
        assert.equal(v.element('coords').textContent, 'No shared position');
        v.recenter();
    });
}
test('local session expiry clears the map even without another server response', async () => {
    const v = await viewer();
    assert.equal(v.maps.length, 1);
    v.advance(3600000);
    assert.equal(v.maps[0].removed, true);
    assert.equal(v.element('recenter').hidden, true);
    assert.equal(v.element('coords').textContent, 'No shared position');
});
test('sender name is text and the circular marker photo uses only authenticated session requests', async () => {
    const v = await viewer(undefined, { name: '<img src=x onerror=alert(1)>', avatarVersion: 1 });
    assert.equal(v.element('sender-name').textContent, '<img src=x onerror=alert(1)>');
    const request = v.requests.find(r => r.url.endsWith('/avatar'));
    assert.ok(request);
    assert.equal(request.options.headers.Authorization, 'Bearer secret');
    assert.equal(request.options.cache, 'no-store');
    assert.equal(v.blobs.length, 1);
    const node = v.markers[0].icon.html;
    assert.equal(node.children[0].tag, 'img');
    assert.equal(node.children[0].src, 'blob:photo-0');
    assert.doesNotMatch(JSON.stringify(v.requests), /group/);
});
test('photo version changes and terminal states revoke old blobs', async () => {
    const v = await viewer(undefined, { name: 'Alex Rider', avatarVersion: 1 });
    await v.identity({ name: 'Alex Rider', avatarVersion: 2 });
    assert.deepEqual(v.revoked, ['blob:photo-0']);
    assert.equal(v.blobs.length, 2);
    await v.end('ended');
    assert.deepEqual(v.revoked, ['blob:photo-0', 'blob:photo-1']);
    assert.equal(v.element('sender-name').textContent, '');
});
test('missing photo uses initials and legacy simulator uses a safe fallback', async () => {
    const v = await viewer(undefined, { name: 'Alex Rider', avatarVersion: 1 }, 404);
    assert.equal(v.markers[0].icon.html.textContent, 'AR');
    assert.equal(v.blobs.length, 0);
    const legacy = await viewer();
    assert.equal(legacy.markers[0].icon.html.textContent, 'R');
    assert.equal(legacy.requests.filter(r => r.url.endsWith('/avatar')).length, 0);
});
test('local expiry revokes the current photo without another server response', async () => {
    const v = await viewer(undefined, { name: 'Alex', avatarVersion: 1 });
    v.advance(3600000);
    assert.deepEqual(v.revoked, ['blob:photo-0']);
});
test('temporary photo failures retry at a bounded rate and recover without a profile change', async () => {
    const v = await viewer(undefined, { name: 'Alex Rider', avatarVersion: 1 }, 503);
    assert.equal(v.blobs.length, 0);
    v.photoStatus(200);
    v.advance(1000);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(v.requests.filter(r => r.url.endsWith('/avatar')).length, 1);
    v.advance(4000);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(v.requests.filter(r => r.url.endsWith('/avatar')).length, 2);
    assert.equal(v.blobs.length, 1);
});
test('an undecodable photo revokes its blob and restores initials', async () => {
    const v = await viewer(undefined, { name: 'Alex Rider', avatarVersion: 1 });
    v.markers[0].icon.html.children[0].listeners.get('error')();
    assert.deepEqual(v.revoked, ['blob:photo-0']);
    assert.equal(v.markers[0].icon.html.textContent, 'AR');
});
