import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createContext, runInContext } from 'node:vm';

const source = await readFile(new URL('../public/view.js', import.meta.url), 'utf8');

async function viewer(initialLocation: any = { lat: 41, lon: 29, accuracyM: 8 }) {
  let now = Date.now();
  let response: any = {
    state: initialLocation ? 'live' : 'waiting', source: 'device', expiresAt: now + 3600000,
    location: initialLocation && { ...initialLocation, observedAt: now },
  };
  let httpStatus = 200;
  let networkError = false;
  const elements = new Map<string, any>();
  const element = (id: string) => {
    if (!elements.has(id)) elements.set(id, {
      hidden: true, textContent: '', listeners: new Map(),
      addEventListener(event: string, handler: () => void) { this.listeners.set(event, handler); },
      removeAttribute(name: string) { delete (this as any)[name]; },
    });
    return elements.get(id);
  };
  const maps: any[] = [];
  const markers: any[] = [];
  const context = createContext({
    URLSearchParams, AbortSignal, location: { hash: '#id=test&token=secret', pathname: '/view.html' },
    history: { replaceState() {} }, document: { getElementById: element }, setInterval() {},
    Date: class extends Date { static now() { return now; } },
    fetch: async () => {
      if (networkError) throw new Error('offline');
      return { status: httpStatus, ok: httpStatus === 200, json: async () => structuredClone(response) };
    },
    L: {
      map() {
        const map = {
          center: [], zoom: 0, removed: false,
          setView(center: number[], zoom: number) { this.center = Array.from(center); this.zoom = zoom; return this; },
          remove() { this.removed = true; },
        };
        maps.push(map); return map;
      },
      tileLayer() { return { addTo() {} }; },
      circleMarker(position: number[]) {
        const marker = {
          position: Array.from(position),
          addTo() { return this; },
          setLatLng(position: number[]) { this.position = Array.from(position); return this; },
        };
        markers.push(marker); return marker;
      },
    },
  });
  runInContext(source, context);
  await new Promise(resolve => setImmediate(resolve));
  return {
    element, maps, markers,
    async update(location: any) {
      response.location = location && { ...location, accuracyM: 8, observedAt: now };
      await runInContext('poll()', context);
    },
    async end(state: string, status = 200) {
      response.state = state; response.location = null; httpStatus = status;
      await runInContext('poll()', context);
    },
    async disconnect() { networkError = true; await runInContext('poll()', context); },
    advance(ms: number) { now += ms; runInContext('render()', context); },
    recenter() { element('recenter').listeners.get('click')(); },
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
