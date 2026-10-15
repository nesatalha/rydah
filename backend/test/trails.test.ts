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
const upload = (s: any, observedAt = Date.now(), lat = 41) => call(`/api/sessions/${s.id}/location`, 'PUT', s.writeToken, {
    seq: ++seq, lat, lon: 29, accuracyM: 8, observedAt
});
const points = async (id: string) => (await db.prepare('SELECT count(*) AS n FROM session_points WHERE session_id=?').bind(id).first<{ n: number }>())!.n;
const read = (s: any, query = '') => call(`/api/sessions/${s.id}${query}`, 'GET', s.readToken);
before(async () => {
    mf = new Miniflare({ modules: true, script: 'export default {fetch(){return new Response("ok")}}', d1Databases: { DB: 'trails' } });
    db = await mf.getD1Database('DB') as unknown as D1Database;
    for (const migration of ['0001_sessions.sql', '0002_private_groups.sql', '0003_session_trails.sql', '0004_session_speed.sql'])
        await db.exec(await readFile(`migrations/${migration}`, 'utf8'));
});
after(async () => {
    await mf?.dispose();
});
test('session trail option validates, defaults off and is part of exact retry', async () => {
    const d = await solo();
    for (const trail of ['10m', 15, null])
        assert.equal((await call('/api/me/sessions', 'POST', d.deviceToken, options('viewer', trail as any))).status, 400);
    const plain = options('viewer');
    const created = await data(await call('/api/me/sessions', 'POST', d.deviceToken, plain), 201);
    assert.equal(created.trail, 'off');
    assert.equal((await call('/api/me/sessions', 'POST', d.deviceToken, { ...plain, trail: '30m' })).status, 409);
    assert.equal((await data(await call('/api/me/sessions', 'POST', d.deviceToken, { ...plain, trail: 'off' }))).expiresAt, created.expiresAt);
    await call(`/api/sessions/${plain.id}`, 'DELETE', plain.writeToken);
    const whole = options('viewer', 'session');
    const first = await data(await call('/api/me/sessions', 'POST', d.deviceToken, whole), 201);
    assert.equal(first.trail, 'session');
    const { trail: _omit, ...withoutTrail } = whole;
    assert.equal((await call('/api/me/sessions', 'POST', d.deviceToken, withoutTrail)).status, 409);
    const again = await data(await call('/api/me/sessions', 'POST', d.deviceToken, whole));
    assert.equal(again.expiresAt, first.expiresAt);
    await call(`/api/sessions/${whole.id}`, 'DELETE', whole.writeToken);
});
test('trail off stores no history rows', async () => {
    const s = await share(await solo());
    assert.equal((await upload(s)).status, 200);
    assert.equal(await points(s.id), 0);
    assert.equal((await data(await read(s))).trail, null);
});
test('trail thins to one point per 10 s and prunes outside the window', async () => {
    const s = await share(await solo(), 'viewer', '15m');
    const now = Date.now();
    for (const offset of [-100000, -96000, -88000, -78000, -77000, -60000])
        assert.equal((await data(await upload(s, now + offset))).accepted, true);
    assert.equal(await points(s.id), 4);
    await db.prepare('UPDATE session_points SET observed_at=observed_at-1000000 WHERE session_id=? AND observed_at<?').bind(s.id, now - 85000).run();
    const hidden = await data(await read(s));
    assert.equal(hidden.trail.points.length, 2);
    assert.equal(hidden.trail.setting, '15m');
    assert.ok(hidden.trail.windowStartsAt >= now - 900000);
    await upload(s, now - 40000);
    assert.equal(await points(s.id), 3);
});
test('viewer since returns only newer points and reset semantics', async () => {
    const s = await share(await solo(), 'viewer', 'session');
    const now = Date.now();
    await upload(s, now - 60000, 41.1);
    await upload(s, now - 40000, 41.2);
    const full = await data(await read(s));
    assert.equal(full.trail.reset, true);
    assert.equal(full.trail.windowStartsAt, null);
    assert.equal(full.trail.points.length, 2);
    assert.deepEqual(full.trail.points[1].slice(1, 3), [41.2, 29]);
    const maxSeq = full.trail.points[1][0];
    const none = await data(await read(s, `?since=${maxSeq}`));
    assert.equal(none.trail.reset, false);
    assert.deepEqual(none.trail.points, []);
    await upload(s, now - 20000, 41.3);
    const next = await data(await read(s, `?since=${maxSeq}`));
    assert.equal(next.trail.points.length, 1);
    assert.equal(next.trail.points[0][1], 41.3);
    assert.equal((await read(s, '?since=abc')).status, 400);
    assert.equal((await read(s, '?since=1234567890123456')).status, 400);
});
test('stop, removal, leave and group deletion delete trail points immediately', async () => {
    const stopped = await share(await solo(), 'viewer', 'session');
    await upload(stopped);
    assert.equal(await points(stopped.id), 1);
    await call(`/api/sessions/${stopped.id}`, 'DELETE', stopped.writeToken);
    assert.equal(await points(stopped.id), 0);
    const g = await group();
    const removed = await join(g), leaving = await join(g);
    const sessions = [await share(g.owner, 'group', 'session'), await share(removed, 'group', '30m'), await share(leaving, 'viewer', '15m')];
    for (const s of sessions) await upload(s);
    assert.deepEqual(await Promise.all(sessions.map(s => points(s.id))), [1, 1, 1]);
    await call(`/api/group/members/${removed.deviceId}`, 'DELETE', g.owner.deviceToken);
    assert.equal(await points(sessions[1].id), 0);
    await call('/api/group/membership', 'DELETE', leaving.deviceToken);
    assert.equal(await points(sessions[2].id), 0);
    await call('/api/group', 'DELETE', g.owner.deviceToken);
    assert.equal(await points(sessions[0].id), 0);
});
test('racing upload and stop never leave trail points', async () => {
    for (let i = 0; i < 5; i++) {
        const s = await share(await solo(), 'viewer', 'session');
        await Promise.all([upload(s), call(`/api/sessions/${s.id}`, 'DELETE', s.writeToken)]);
        assert.equal(await points(s.id), 0);
    }
});
test('scheduled cleanup removes expired session points', async () => {
    const s = await share(await solo(), 'viewer', 'session');
    await upload(s);
    await db.prepare('INSERT INTO session_points(session_id,seq,lat,lon,observed_at) VALUES(?,?,?,?,?)').bind('orphan', 1, 1, 1, Date.now()).run();
    await db.prepare('UPDATE sessions SET expires_at=? WHERE id=?').bind(Date.now() - 1, s.id).run();
    assert.equal((await read(s)).status, 410);
    await worker.scheduled({} as any, env());
    assert.equal(await points(s.id), 0);
    assert.equal(await points('orphan'), 0);
});
test('group roster returns incremental trails per member with expiresAt cursor', async () => {
    const g = await group();
    const member = await join(g);
    const a = await share(g.owner, 'group', 'session'), b = await share(member, 'group', '30m');
    const now = Date.now();
    await upload(a, now - 50000, 40.1);
    await upload(a, now - 30000, 40.2);
    await upload(b, now - 30000, 50.1);
    const first = await data(await call('/api/group?trailSince=', 'GET', member.deviceToken));
    const byId = (r: any, id: string) => r.members.find((m: any) => m.deviceId === id).sharing.trail;
    assert.equal(byId(first, g.owner.deviceId).reset, true);
    assert.equal(byId(first, g.owner.deviceId).points.length, 2);
    assert.equal(byId(first, member.deviceId).points.length, 1);
    const cursor = (id: string, expiresAt: number, r: any) => `${id}:${expiresAt}:${byId(r, id).points.at(-1)[0]}`;
    await upload(a, now - 10000, 40.3);
    const q = [cursor(g.owner.deviceId, a.expiresAt, first), cursor(member.deviceId, b.expiresAt, first)].join(',');
    const second = await data(await call(`/api/group?trailSince=${encodeURIComponent(q)}`, 'GET', member.deviceToken));
    assert.equal(byId(second, g.owner.deviceId).reset, false);
    assert.deepEqual(byId(second, g.owner.deviceId).points.map((p: any) => p[1]), [40.3]);
    assert.deepEqual(byId(second, member.deviceId).points, []);
    const stale = `${g.owner.deviceId}:${a.expiresAt - 1}:999`;
    const reset = await data(await call(`/api/group?trailSince=${encodeURIComponent(stale)}`, 'GET', member.deviceToken));
    assert.equal(byId(reset, g.owner.deviceId).reset, true);
    assert.equal(byId(reset, g.owner.deviceId).points.length, 3);
    await call(`/api/sessions/${b.id}`, 'DELETE', b.writeToken);
    const viewerOnly = await share(member, 'viewer', 'session');
    await upload(viewerOnly);
    const isolated = await data(await call('/api/group?trailSince=', 'GET', g.owner.deviceToken));
    assert.equal(isolated.members.find((m: any) => m.deviceId === member.deviceId).sharing, null);
    assert.doesNotMatch(JSON.stringify(isolated), new RegExp(viewerOnly.id));
    assert.equal((await call('/api/group?trailSince=bad', 'GET', member.deviceToken)).status, 400);
    const many = Array.from({ length: 33 }, (_, i) => `d${i}:1:1`).join(',');
    assert.equal((await call(`/api/group?trailSince=${many}`, 'GET', member.deviceToken)).status, 400);
});
test('trail off members have null trail in the roster', async () => {
    const g = await group();
    const s = await share(g.owner, 'group');
    await upload(s);
    const roster = await data(await call('/api/group?trailSince=', 'GET', g.owner.deviceToken));
    assert.equal(roster.members[0].sharing.trail, null);
});
test('roster without trailSince (older apps) returns no trails; inflated cursors only narrow the reply', async () => {
    const g = await group();
    const member = await join(g);
    const s = await share(g.owner, 'group', 'session');
    await upload(s, Date.now() - 20000);
    const legacy = await data(await call('/api/group', 'GET', member.deviceToken));
    assert.equal(legacy.members[0].sharing.trail, null);
    assert.ok(legacy.members[0].sharing.location);
    const inflated = await data(await call(`/api/group?trailSince=${g.owner.deviceId}:${s.expiresAt}:999999`, 'GET', member.deviceToken));
    assert.deepEqual(inflated.members[0].sharing.trail.points, []);
    assert.equal(inflated.members[0].sharing.trail.reset, false);
    const proto = await data(await call('/api/group?trailSince=__proto__:1:1', 'GET', member.deviceToken));
    assert.equal(proto.members[0].sharing.trail.points.length, 1);
    const ahead = await data(await read(s, '?since=999999'));
    assert.deepEqual(ahead.trail.points, []);
});
test('migration 0003 preserves existing session rows', async () => {
    const local = new Miniflare({ modules: true, script: 'export default {fetch(){return new Response("ok")}}', d1Databases: { DB: 'migrate' } });
    try {
        const d = await local.getD1Database('DB') as unknown as D1Database;
        for (const migration of ['0001_sessions.sql', '0002_private_groups.sql'])
            await d.exec(await readFile(`migrations/${migration}`, 'utf8'));
        await d.prepare("INSERT INTO sessions(id,write_hash,read_hash,source,expires_at) VALUES('old','w','r','device',1)").run();
        await d.exec(await readFile('migrations/0003_session_trails.sql', 'utf8'));
        assert.equal((await d.prepare("SELECT trail FROM sessions WHERE id='old'").first<{ trail: string }>())!.trail, 'off');
    }
    finally {
        await local.dispose();
    }
});
