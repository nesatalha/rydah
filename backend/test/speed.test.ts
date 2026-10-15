import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { Miniflare } from 'miniflare';
import { readFile } from 'node:fs/promises';
import worker from '../src/index.js';
let mf: Miniflare, db: D1Database;
const credential = () => crypto.randomUUID().replaceAll('-', '') + crypto.randomUUID().replaceAll('-', '');
const env = () => ({ DB: db, CREATOR_KEY: 'test-key', ASSETS: { fetch: async () => new Response('asset') } } as any);
const call = (path: string, method = 'GET', token = '', body?: unknown) => worker.fetch(new Request(`https://demo.test${path}`, {
    method, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body)
}), env());
const data = async (r: Response, status = 200) => {
    assert.equal(r.status, status, await r.clone().text());
    return await r.json() as any;
};
const device = () => ({ deviceId: crypto.randomUUID(), deviceToken: credential(), name: 'Rider' });
const group = async () => {
    const g = await data(await call('/api/admin/groups', 'POST', 'test-key', { name: 'Friends' }), 201);
    const owner = { ...device() };
    await data(await call('/api/enroll', 'POST', g.invitation.token, owner));
    return { ...g, owner };
};
const join = async (g: any) => {
    const invitation = await data(await call('/api/group/invitations', 'POST', g.owner.deviceToken), 201);
    const member = device();
    await data(await call('/api/enroll', 'POST', invitation.token, member));
    return member;
};
const solo = async () => {
    const d = device();
    await data(await call('/api/devices', 'POST', '', d), 201);
    return d;
};
const options = (audience: string, trail?: string) => ({
    id: crypto.randomUUID(), readToken: credential(), writeToken: credential(), audience, durationMinutes: 60, ...(trail === undefined ? {} : { trail })
});
const share = async (d: any, audience = 'viewer', trail?: string) => {
    const o = options(audience, trail);
    return { ...o, ...await data(await call('/api/me/sessions', 'POST', d.deviceToken, o), 201) };
};
let seq = 0;
const upload = (s: any, extra: any = {}, observedAt = Date.now()) => call(`/api/sessions/${s.id}/location`, 'PUT', s.writeToken, {
    seq: ++seq, lat: 41, lon: 29, accuracyM: 8, observedAt, ...extra
});
const stored = async (id: string) => await db.prepare('SELECT speed_mps AS speed,speed_accuracy_mps AS accuracy FROM sessions WHERE id=?').bind(id).first<{ speed: number | null; accuracy: number | null }>();
const read = (s: any, query = '') => call(`/api/sessions/${s.id}${query}`, 'GET', s.readToken);
before(async () => {
    mf = new Miniflare({ modules: true, script: 'export default {fetch(){return new Response("ok")}}', d1Databases: { DB: 'speed' } });
    db = await mf.getD1Database('DB') as unknown as D1Database;
    for (const migration of ['0001_sessions.sql', '0002_private_groups.sql', '0003_session_trails.sql', '0004_session_speed.sql'])
        await db.exec(await readFile(`migrations/${migration}`, 'utf8'));
});
after(async () => {
    await mf?.dispose();
});
test('upload accepts optional speed and accuracy and returns them on viewer and group reads', async () => {
    const g = await group();
    const s = await share(g.owner, 'group');
    assert.equal((await data(await upload(s, { speedMps: 13.4, speedAccuracyMps: 1.2 }))).accepted, true);
    const viewer = await data(await read(s));
    assert.equal(viewer.location.speedMps, 13.4);
    assert.equal(viewer.location.speedAccuracyMps, 1.2);
    const roster = await data(await call('/api/group', 'GET', g.owner.deviceToken));
    assert.equal(roster.members[0].sharing.location.speedMps, 13.4);
    assert.equal(roster.members[0].sharing.location.speedAccuracyMps, 1.2);
});
test('upload without speed stores null and overwrites a previous speed', async () => {
    const s = await share(await solo());
    await upload(s, { speedMps: 20, speedAccuracyMps: 3 });
    await upload(s);
    const viewer = await data(await read(s));
    assert.equal(viewer.location.speedMps, null);
    assert.equal(viewer.location.speedAccuracyMps, null);
    assert.deepEqual({ ...await stored(s.id) }, { speed: null, accuracy: null });
});
test('invalid speed values return 400; bounds and null are accepted', async () => {
    const s = await share(await solo());
    for (const bad of [-1, 100.1, '12', {}, true]) {
        assert.equal((await upload(s, { speedMps: bad })).status, 400, `speedMps ${JSON.stringify(bad)}`);
        assert.equal((await upload(s, { speedAccuracyMps: bad })).status, 400, `speedAccuracyMps ${JSON.stringify(bad)}`);
    }
    for (const ok of [0, 100, null])
        assert.equal((await upload(s, { speedMps: ok, speedAccuracyMps: ok })).status, 200);
});
test('rejected out-of-order upload keeps the newer speed', async () => {
    const s = await share(await solo());
    const now = Date.now();
    await upload(s, { speedMps: 15 }, now);
    const stale = await call(`/api/sessions/${s.id}/location`, 'PUT', s.writeToken, { seq: 1, lat: 41, lon: 29, accuracyM: 8, observedAt: now - 5000, speedMps: 2 });
    assert.equal((await data(stale)).accepted, false);
    assert.equal((await stored(s.id))!.speed, 15);
});
test('stop, removal, leave, group deletion and expired sweep clear stored speed', async () => {
    const stopped = await share(await solo());
    await upload(stopped, { speedMps: 10, speedAccuracyMps: 1 });
    await call(`/api/sessions/${stopped.id}`, 'DELETE', stopped.writeToken);
    assert.deepEqual({ ...await stored(stopped.id) }, { speed: null, accuracy: null });
    const g = await group();
    const removed = await join(g), leaving = await join(g);
    const sessions = [await share(g.owner, 'group'), await share(removed, 'group'), await share(leaving, 'viewer')];
    for (const s of sessions) await upload(s, { speedMps: 10, speedAccuracyMps: 1 });
    await call(`/api/group/members/${removed.deviceId}`, 'DELETE', g.owner.deviceToken);
    assert.equal((await stored(sessions[1].id))!.speed, null);
    await call('/api/group/membership', 'DELETE', leaving.deviceToken);
    assert.equal((await stored(sessions[2].id))!.speed, null);
    await call('/api/group', 'DELETE', g.owner.deviceToken);
    assert.deepEqual({ ...await stored(sessions[0].id) }, { speed: null, accuracy: null });
    const d = await solo();
    const expiring = await share(d);
    await upload(expiring, { speedMps: 10, speedAccuracyMps: 1 });
    await db.prepare('UPDATE sessions SET expires_at=? WHERE id=?').bind(Date.now() - 1, expiring.id).run();
    await share(d);
    assert.deepEqual({ ...await stored(expiring.id) }, { speed: null, accuracy: null });
});
test('racing upload and stop never leave a stored speed', async () => {
    for (let i = 0; i < 5; i++) {
        const s = await share(await solo());
        await Promise.all([upload(s, { speedMps: 12, speedAccuracyMps: 1 }), call(`/api/sessions/${s.id}`, 'DELETE', s.writeToken)]);
        assert.deepEqual({ ...await stored(s.id) }, { speed: null, accuracy: null });
    }
});
test('migration 0004 preserves existing session rows with null speed', async () => {
    const local = new Miniflare({ modules: true, script: 'export default {fetch(){return new Response("ok")}}', d1Databases: { DB: 'migrate-speed' } });
    try {
        const d = await local.getD1Database('DB') as unknown as D1Database;
        for (const migration of ['0001_sessions.sql', '0002_private_groups.sql', '0003_session_trails.sql'])
            await d.exec(await readFile(`migrations/${migration}`, 'utf8'));
        await d.prepare("INSERT INTO sessions(id,write_hash,read_hash,source,expires_at,lat,lon) VALUES('old','w','r','device',1,41,29)").run();
        await d.exec(await readFile('migrations/0004_session_speed.sql', 'utf8'));
        const row = await d.prepare("SELECT speed_mps,speed_accuracy_mps,lat FROM sessions WHERE id='old'").first<any>();
        assert.deepEqual({ ...row }, { speed_mps: null, speed_accuracy_mps: null, lat: 41 });
    }
    finally {
        await local.dispose();
    }
});
