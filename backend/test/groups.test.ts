import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { Miniflare } from 'miniflare';
import { readFile } from 'node:fs/promises';
import worker from '../src/index.js';
let mf: Miniflare, db: D1Database;
const credential = () => crypto.randomUUID().replaceAll('-', '') + crypto.randomUUID().replaceAll('-', '');
const call = (path: string, method = 'GET', token = '', body?: unknown) => worker.fetch(new Request(`https://demo.test${path}`, {
    method, headers: { Authorization: `Bearer ${token}`, 'Content-Type': body instanceof Uint8Array ? 'image/png' : 'application/json' }, body: body === undefined ? undefined : body instanceof Uint8Array ? body : JSON.stringify(body)
}), {
    DB: db, CREATOR_KEY: 'test-key', ASSETS: { fetch: async () => new Response('asset') }
} as any);
const data = async (r: Response, status = 200) => {
    assert.equal(r.status, status, await r.clone().text());
    assert.equal(r.headers.get('Cache-Control'), 'no-store');
    assert.equal(r.headers.get('Referrer-Policy'), 'no-referrer');
    return await r.json() as any;
};
const device = () => ({
    deviceId: crypto.randomUUID(), deviceToken: credential(), name: 'Rider'
});
const create = async () => data(await call('/api/admin/groups', 'POST', 'test-key', { name: 'Friends' }), 201);
const enroll = async (invitation: any, d = device()) => {
    const result = await data(await call('/api/enroll', 'POST', invitation.token, d));
    return { ...d, ...result };
};
const group = async () => {
    const g = await create();
    const owner = await enroll(g.invitation);
    return { ...g, owner };
};
const invite = async (g: any) => data(await call('/api/group/invitations', 'POST', g.owner.deviceToken), 201);
const session = async (d: any, audience = 'group', durationMinutes = 60) => {
    const credentials = {
        id: crypto.randomUUID(), readToken: credential(), writeToken: credential(), audience, durationMinutes
    };
    const result = await data(await call('/api/me/sessions', 'POST', d.deviceToken, credentials), 201);
    return { ...credentials, ...result };
};
const upload = (s: any) => call(`/api/sessions/${s.id}/location`, 'PUT', s.writeToken, {
    seq: 1, lat: 41, lon: 29, accuracyM: 8, observedAt: Date.now()
});
const avatarPNG = new Uint8Array(await readFile(new URL('./fixtures/avatar.png', import.meta.url)));
const png = (width = 128, height = 128) => {
    const bytes = avatarPNG.slice();
    const v = new DataView(bytes.buffer);
    v.setUint32(16, width);
    v.setUint32(20, height);
    return bytes;
};
before(async () => {
    mf = new Miniflare({
        modules: true, script: 'export default {fetch(){return new Response("ok")}}', d1Databases: { DB: 'groups' }
    });
    db = await mf.getD1Database('DB') as unknown as D1Database;
    for (const migration of ['0001_sessions.sql', '0002_private_groups.sql', '0003_session_trails.sql'])
        await db.exec(await readFile(`migrations/${migration}`, 'utf8'));
});
after(async () => {
    await mf?.dispose();
});
test('creator authorization, owner enrollment, private roster and one-use invitation retry', async () => {
    assert.equal((await call('/api/admin/groups', 'POST', 'wrong', { name: 'Friends' })).status, 401);
    const g = await group();
    assert.equal(g.owner.role, 'owner');
    assert.match(g.invitation.joinUrl, /\/join.html#token=/);
    const me = await data(await call('/api/me', 'GET', g.owner.deviceToken));
    assert.equal(me.deviceId, g.owner.deviceId);
    assert.equal(me.groupId, g.groupId);
    await enroll(g.invitation, g.owner);
    assert.equal((await call('/api/enroll', 'POST', g.invitation.token, device())).status, 409);
    const member = await enroll(await invite(g));
    assert.equal(member.role, 'member');
    const roster = await data(await call('/api/group', 'GET', member.deviceToken));
    assert.equal(roster.members.length, 2);
    assert.equal(roster.members[0].sharing, null);
    assert.doesNotMatch(JSON.stringify(roster), /token|hash|invitation/i);
    assert.equal((await call('/api/group/invitations', 'POST', member.deviceToken)).status, 403);
    const invitations = await data(await call('/api/group/invitations', 'GET', g.owner.deviceToken));
    assert.doesNotMatch(JSON.stringify(invitations), /token|hash/);
});
test('invitation consumption is atomic across different credentials and exact retries', async () => {
    const g = await group();
    const invitation = await invite(g);
    const first = device(), second = device();
    const responses = await Promise.all([call('/api/enroll', 'POST', invitation.token, first), call('/api/enroll', 'POST', invitation.token, second)]);
    assert.deepEqual(responses.map(r => r.status).sort(), [200, 409]);
    const retryInvitation = await invite(g), d = device();
    const retries = await Promise.all([call('/api/enroll', 'POST', retryInvitation.token, d), call('/api/enroll', 'POST', retryInvitation.token, d)]);
    assert.deepEqual(retries.map(r => r.status), [200, 200]);
});
test('revoked, expired invitations and removed membership cannot recreate access', async () => {
    const g = await group(), revoked = await invite(g), expired = await invite(g), used = await invite(g);
    const d = await enroll(used);
    assert.equal((await call(`/api/group/invitations/${revoked.id}`, 'DELETE', g.owner.deviceToken)).status, 204);
    assert.equal((await call('/api/enroll', 'POST', revoked.token, device())).status, 410);
    await db.prepare('UPDATE invitations SET expires_at=? WHERE id=?').bind(Date.now() - 1, expired.id).run();
    assert.equal((await call('/api/enroll', 'POST', expired.token, device())).status, 410);
    assert.equal((await call(`/api/group/members/${d.deviceId}`, 'DELETE', g.owner.deviceToken)).status, 204);
    assert.equal((await call('/api/enroll', 'POST', used.token, d)).status, 410);
    assert.equal((await call('/api/enroll', 'POST', (await invite(g)).token, d)).status, 409);
});
test('profile names, private avatar access, deletion and group boundary', async () => {
    const g = await group(), d = await enroll(await invite(g)), other = await group();
    assert.equal((await call('/api/me', 'PUT', d.deviceToken, { name: ' '.repeat(4) })).status, 400);
    assert.equal((await call('/api/me', 'PUT', d.deviceToken, { name: 'x'.repeat(61) })).status, 400);
    const profile = await data(await call('/api/me', 'PUT', d.deviceToken, { name: '<b>Alex</b>' }));
    assert.equal(profile.name, '<b>Alex</b>');
    assert.equal((await call('/api/me/avatar', 'PUT', d.deviceToken, png(127))).status, 400);
    assert.equal((await call('/api/me/avatar', 'PUT', d.deviceToken, new Uint8Array(65537))).status, 400);
    const avatar = await data(await call('/api/me/avatar', 'PUT', d.deviceToken, png()));
    assert.ok(avatar.avatarVersion);
    const photo = await call(`/api/group/members/${d.deviceId}/avatar`, 'GET', g.owner.deviceToken);
    assert.equal(photo.status, 200);
    assert.equal(photo.headers.get('Content-Type'), 'image/png');
    assert.equal(photo.headers.get('X-Content-Type-Options'), 'nosniff');
    assert.equal(photo.headers.get('Cache-Control'), 'no-store');
    assert.equal((await call(`/api/group/members/${d.deviceId}/avatar`, 'GET', other.owner.deviceToken)).status, 404);
    assert.equal((await call(`/api/group/members/${d.deviceId}/avatar`)).status, 401);
    assert.equal((await call('/api/me/avatar', 'DELETE', d.deviceToken)).status, 204);
    assert.equal((await call(`/api/group/members/${d.deviceId}/avatar`, 'GET', g.owner.deviceToken)).status, 404);
});
test('meeting points are editable by members, validated, and isolated', async () => {
    const g = await group(), d = await enroll(await invite(g)), other = await group();
    assert.equal((await call('/api/group/meeting-point', 'PUT', d.deviceToken, {
        lat: 91, lon: 29, label: 'Meet'
    })).status, 400);
    const point = await data(await call('/api/group/meeting-point', 'PUT', d.deviceToken, {
        lat: 41, lon: 29, label: 'Cafe'
    }));
    assert.equal(point.updatedBy, d.deviceId);
    assert.equal((await data(await call('/api/group', 'GET', g.owner.deviceToken))).meetingPoint.label, 'Cafe');
    assert.equal((await data(await call('/api/group', 'GET', other.owner.deviceToken))).meetingPoint, null);
    assert.equal((await call('/api/group/meeting-point', 'DELETE', d.deviceToken)).status, 204);
    assert.equal((await data(await call('/api/group', 'GET', d.deviceToken))).meetingPoint, null);
});
test('device sessions use requested duration and exact retry preserves expiry and options', async () => {
    const g = await group();
    for (const duration of [30, 60, 120, 240]) {
        const s = await session(g.owner, 'viewer', duration);
        assert.ok(Math.abs(s.expiresAt - Date.now() - duration * 60000) < 2000);
        const retry = await data(await call('/api/me/sessions', 'POST', g.owner.deviceToken, s), 200);
        assert.equal(retry.expiresAt, s.expiresAt);
        assert.equal(retry.audience, s.audience);
        assert.equal((await call('/api/me/sessions', 'POST', g.owner.deviceToken, { ...s, readToken: credential() })).status, 409);
        assert.equal((await call(`/api/sessions/${s.id}`, 'DELETE', s.writeToken)).status, 204);
        assert.equal((await call('/api/me/sessions', 'POST', g.owner.deviceToken, s)).status, 410);
    }
    const s = await session(g.owner);
    assert.equal((await call('/api/me/sessions', 'POST', g.owner.deviceToken, {
        id: crypto.randomUUID(), readToken: credential(), writeToken: credential(), audience: 'group', durationMinutes: 15
    })).status, 400);
    assert.equal((await call('/api/me/sessions', 'POST', g.owner.deviceToken, {
        id: crypto.randomUUID(), readToken: credential(), writeToken: credential(), audience: 'group'
    })).status, 409);
    await call(`/api/sessions/${s.id}`, 'DELETE', s.writeToken);
});
test('viewer shares disclose sender identity but only group shares appear in roster', async () => {
    const g = await group(), d = await enroll(await invite(g));
    await call('/api/me/avatar', 'PUT', d.deviceToken, png());
    const viewer = await session(d, 'viewer');
    await upload(viewer);
    const spouse = await data(await call(`/api/sessions/${viewer.id}`, 'GET', viewer.readToken));
    assert.equal(spouse.sender.name, d.name);
    assert.doesNotMatch(JSON.stringify(spouse), /group|member|meetingPoint|deviceId/);
    assert.equal((await data(await call('/api/group', 'GET', g.owner.deviceToken))).members.find((m: any) => m.deviceId === d.deviceId).sharing, null);
    assert.equal((await call(`/api/sessions/${viewer.id}/avatar`, 'GET', viewer.readToken)).status, 200);
    assert.equal((await call(`/api/sessions/${viewer.id}/avatar`, 'GET', viewer.writeToken)).status, 401);
    await call(`/api/sessions/${viewer.id}`, 'DELETE', viewer.writeToken);
    assert.equal((await call(`/api/sessions/${viewer.id}/avatar`, 'GET', viewer.readToken)).status, 410);
    const shared = await session(d);
    await upload(shared);
    const roster = await data(await call('/api/group', 'GET', g.owner.deviceToken));
    assert.equal(roster.members.find((m: any) => m.deviceId === d.deviceId).sharing.location.lat, 41);
});
test('removal and racing upload clear group and spouse sessions without resurrection', async () => {
    const g = await group(), d = await enroll(await invite(g)), s = await session(d, 'viewer');
    await upload(s);
    await Promise.all([upload(s), call(`/api/group/members/${d.deviceId}`, 'DELETE', g.owner.deviceToken)]);
    const ended = await data(await call(`/api/sessions/${s.id}`, 'GET', s.readToken));
    assert.equal(ended.state, 'ended');
    assert.equal(ended.location, null);
    assert.equal(ended.sender, null);
    assert.equal((await upload(s)).status, 410);
    assert.equal((await call('/api/group', 'GET', d.deviceToken)).status, 403);
    const viewer = await session(d, 'viewer');
    assert.equal((await call(`/api/sessions/${viewer.id}`, 'DELETE', viewer.writeToken)).status, 204);
    assert.equal((await call('/api/me/sessions', 'POST', d.deviceToken, {
        id: crypto.randomUUID(), readToken: credential(), writeToken: credential(), audience: 'group'
    })).status, 403);
});
test('leave preserves profile, owner cannot leave or remove self, deletion revokes all', async () => {
    const g = await group(), d = await enroll(await invite(g)), s = await session(d);
    assert.equal((await call('/api/group/membership', 'DELETE', g.owner.deviceToken)).status, 409);
    assert.equal((await call(`/api/group/members/${g.owner.deviceId}`, 'DELETE', g.owner.deviceToken)).status, 409);
    assert.equal((await call('/api/group', 'DELETE', d.deviceToken)).status, 403);
    assert.equal((await call('/api/group/membership', 'DELETE', d.deviceToken)).status, 204);
    assert.equal((await data(await call('/api/me', 'GET', d.deviceToken))).groupId, null);
    assert.equal((await data(await call(`/api/sessions/${s.id}`, 'GET', s.readToken))).state, 'ended');
    const ownerSession = await session(g.owner), unused = await invite(g);
    assert.equal((await call('/api/group', 'DELETE', g.owner.deviceToken)).status, 204);
    assert.equal((await data(await call(`/api/sessions/${ownerSession.id}`, 'GET', ownerSession.readToken))).location, null);
    assert.equal((await call('/api/enroll', 'POST', unused.token, device())).status, 410);
});
test('bounded JSON, credential validation, session expiry and scheduled retention', async () => {
    assert.equal((await call('/api/admin/groups', 'POST', 'test-key', { name: 'x'.repeat(101) })).status, 400);
    assert.equal((await call('/api/admin/groups', 'POST', 'test-key', { name: 'g', padding: 'x'.repeat(20000) })).status, 413);
    const g = await group(), i = await invite(g);
    assert.equal((await call('/api/enroll', 'POST', i.token, { ...device(), deviceToken: 'short' })).status, 400);
    const s = await session(g.owner);
    await upload(s);
    await db.prepare('UPDATE sessions SET expires_at=? WHERE id=?').bind(Date.now() - 1, s.id).run();
    assert.equal((await call(`/api/sessions/${s.id}/avatar`, 'GET', s.readToken)).status, 410);
    assert.equal((await call(`/api/sessions/${s.id}`, 'GET', s.readToken)).status, 410);
    assert.equal((await data(await call('/api/group', 'GET', g.owner.deviceToken))).members[0].sharing, null);
    await db.prepare('UPDATE invitations SET expires_at=? WHERE id=?').bind(Date.now() - 1, i.id).run();
    await worker.scheduled({} as any, { DB: db } as any);
    assert.equal(await db.prepare('SELECT id FROM invitations WHERE id=?').bind(i.id).first(), null);
});
test('revocation before a group snapshot never returns a meeting point with an unauthorized empty roster', async () => {
    const g = await group(), d = await enroll(await invite(g));
    await call('/api/group/meeting-point', 'PUT', d.deviceToken, {
        lat: 41, lon: 29, label: 'Private cafe'
    });
    const wrap = (statement: D1PreparedStatement, sql: string): any => new Proxy(statement, { get(target, key) {
            if (key === 'bind') {
                return (...values: any[]) => wrap(target.bind(...values), sql);
            }
            if ((key === 'first' || key === 'all') && (sql.includes('meeting_lat') || sql.includes('SELECT * FROM groups'))) {
                return async (...args: any[]) => {
                    await db.prepare('UPDATE memberships SET revoked_at=? WHERE group_id=? AND device_id=?').bind(Date.now(), g.groupId, d.deviceId).run();
                    return (target as any)[key](...args);
                };
            }
            const value = (target as any)[key];
            return typeof value === 'function' ? value.bind(target) : value;
        } });
    const revoke = () => db.prepare('UPDATE memberships SET revoked_at=? WHERE group_id=? AND device_id=?').bind(Date.now(), g.groupId, d.deviceId).run();
    // The roster and trails are read in one batch; revoke just before that snapshot runs.
    const racingDb = { prepare(sql: string) {
            return wrap(db.prepare(sql), sql);
        }, async batch(statements: D1PreparedStatement[]) {
            await revoke();
            return db.batch(statements);
        } };
    const response = await worker.fetch(new Request('https://demo.test/api/group', { headers: { Authorization: `Bearer ${d.deviceToken}` } }), { DB: racingDb, CREATOR_KEY: 'test-key' } as any);
    assert.equal(response.status, 403);
    assert.doesNotMatch(await response.text(), /Private cafe/);
});
test('viewer creation which started before membership removal cannot survive revocation', async () => {
    const g = await group(), d = await enroll(await invite(g)), id = crypto.randomUUID();
    const racingDb = { prepare: db.prepare.bind(db), async batch(statements: D1PreparedStatement[]) {
            await db.prepare('UPDATE memberships SET revoked_at=? WHERE group_id=? AND device_id=?').bind(Date.now(), g.groupId, d.deviceId).run();
            return db.batch(statements);
        } };
    const response = await worker.fetch(new Request('https://demo.test/api/me/sessions', {
        method: 'POST', headers: { Authorization: `Bearer ${d.deviceToken}`, 'Content-Type': 'application/json' }, body: JSON.stringify({
            id, readToken: credential(), writeToken: credential(), audience: 'viewer'
        })
    }), { DB: racingDb, CREATOR_KEY: 'test-key' } as any);
    assert.ok([403, 409, 410].includes(response.status), `unexpected status ${response.status}`);
    assert.equal(await db.prepare('SELECT id FROM sessions WHERE id=? AND ended=0').bind(id).first(), null);
});

test('concurrent exact session retries succeed and competing sessions preserve one active share', async () => {
    const g = await group();
    const input = {id: crypto.randomUUID(), readToken: credential(), writeToken: credential(), audience: 'group', durationMinutes: 60};
    const exact = await Promise.all([call('/api/me/sessions', 'POST', g.owner.deviceToken, input), call('/api/me/sessions', 'POST', g.owner.deviceToken, input)]);
    assert.deepEqual(exact.map(r => r.status).sort(), [200, 201]);
    const bodies = await Promise.all(exact.map(r => r.json() as Promise<any>));
    assert.equal(bodies[0].expiresAt, bodies[1].expiresAt);
    await call(`/api/sessions/${input.id}`, 'DELETE', input.writeToken);
    const competing = await Promise.all([call('/api/me/sessions', 'POST', g.owner.deviceToken, {...input, id: crypto.randomUUID()}), call('/api/me/sessions', 'POST', g.owner.deviceToken, {...input, id: crypto.randomUUID()})]);
    assert.deepEqual(competing.map(r => r.status).sort(), [201, 409]);
});
test('devices register without an invitation and share a private link without a group', async () => {
    const d = device();
    const registered = await data(await call('/api/devices', 'POST', '', d), 201);
    assert.equal(registered.deviceId, d.deviceId);
    assert.equal(registered.groupId, null);
    assert.equal(JSON.stringify(registered).includes(d.deviceToken), false);
    // An exact retry after a lost response returns the same identity; other credentials conflict.
    assert.equal((await data(await call('/api/devices', 'POST', '', d))).deviceId, d.deviceId);
    assert.equal((await call('/api/devices', 'POST', '', { ...d, deviceToken: credential() })).status, 409);
    assert.equal((await call('/api/devices', 'POST', '', { ...d, deviceToken: 'short' })).status, 400);
    assert.equal((await call('/api/devices', 'POST', '', { ...d, name: '  ' })).status, 400);
    assert.equal((await call('/api/me/avatar', 'PUT', d.deviceToken, png())).status, 200);
    const s = await session(d, 'viewer');
    assert.equal((await upload(s)).status, 200);
    const view = await data(await call(`/api/sessions/${s.id}`, 'GET', s.readToken));
    assert.equal(view.sender.name, 'Rider');
    assert.equal((await call(`/api/sessions/${s.id}/avatar`, 'GET', s.readToken)).status, 200);
    assert.equal((await call('/api/me/sessions', 'POST', d.deviceToken, {
        id: crypto.randomUUID(), readToken: credential(), writeToken: credential(), audience: 'group', durationMinutes: 60
    })).status, 403);
    // A registered device can still join a group later with an invitation.
    const g = await group();
    const joined = await enroll(await invite(g), d);
    assert.equal(joined.role, 'member');
});
