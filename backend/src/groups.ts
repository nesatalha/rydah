import { body, bearer, creator, Device, device, empty, Env, fail, hash, json, membership, photo, profile, requireMember, secret, Session, sharing, text, trailCursors, trailOutput, TrailPoint, trailWindowSQL, validId, validToken, coordinates } from './core.js';
interface Invitation {
    id: string;
    group_id: string;
    token_hash: string;
    role: 'owner' | 'member';
    expires_at: number;
    consumed_device_id: string | null;
    consumed_at: number | null;
    revoked_at: number | null;
    group_revoked_at: number | null;
}
const invitationOutput = (id: string, token: string, expiresAt: number, url: string) => ({
    id, token, expiresAt, joinUrl: `${new URL(url).origin}/join.html#token=${token}`
});
export async function groups(request: Request, env: Env, path: string): Promise<Response | null> {
    const now = Date.now();
    if (path === '/api/admin/groups' && request.method === 'POST') {
        await creator(request, env);
        const name = text((await body(request)).name, 100), groupId = crypto.randomUUID(), id = crypto.randomUUID(), token = secret(), expiresAt = now + 86400000;
        await env.DB.batch([env.DB.prepare('INSERT INTO groups(id,name) VALUES(?,?)').bind(groupId, name), env.DB.prepare("INSERT INTO invitations(id,group_id,token_hash,role,expires_at) VALUES(?,?,?,'owner',?)").bind(id, groupId, await hash(token), expiresAt)]);
        return json({ groupId, invitation: invitationOutput(id, token, expiresAt, request.url) }, 201);
    }
    if (path === '/api/enroll' && request.method === 'POST') {
        const token = bearer(request);
        if (!validToken(token)) {
            fail('Unauthorized invitation', 401);
        }
        const input = await body(request);
        const name = text(input.name, 60);
        if (!validId(input.deviceId) || !validToken(input.deviceToken)) {
            fail('Invalid device credentials', 400);
        }
        const invitation = await env.DB.prepare('SELECT i.*,g.revoked_at AS group_revoked_at FROM invitations i JOIN groups g ON g.id=i.group_id WHERE i.token_hash=?').bind(await hash(token)).first<Invitation>();
        if (!invitation) {
            fail('Unauthorized invitation', 401);
        }
        if (invitation.revoked_at !== null || invitation.group_revoked_at !== null) {
            fail('Invitation revoked', 410);
        }
        const tokenHash = await hash(input.deviceToken);
        const existing = await env.DB.prepare('SELECT id,token_hash,name,avatar_version FROM devices WHERE id=?').bind(input.deviceId).first<Device>();
        if (existing && existing.token_hash !== tokenHash) {
            fail('Device credentials conflict', 409);
        }
        const previous = await env.DB.prepare('SELECT revoked_at FROM memberships WHERE group_id=? AND device_id=?').bind(invitation.group_id, input.deviceId).first<{
            revoked_at: number | null;
        }>();
        if (invitation.consumed_device_id !== null) {
            if (invitation.consumed_device_id !== input.deviceId || !existing) {
                fail('Invitation already consumed', 409);
            }
            if (!previous || previous.revoked_at !== null) {
                fail('Membership revoked', 410);
            }
        }
        else {
            if (invitation.expires_at <= now) {
                fail('Invitation expired', 410);
            }
            if (previous) {
                fail('Membership already exists or was revoked', 409);
            }
            if (existing && await membership(env, existing.id)) {
                fail('Device already belongs to a group', 409);
            }
            // Every statement repeats the invitation predicate; the D1 batch is a single transaction.
            const eligible = `SELECT 1 
            FROM invitations i 
            JOIN groups g ON g.id=i.group_id 
            WHERE i.id=? 
            AND i.consumed_device_id IS NULL 
            AND i.revoked_at IS NULL 
            AND i.expires_at>? 
            AND g.revoked_at IS NULL`;
            await env.DB.batch([
                env.DB.prepare(`INSERT OR IGNORE INTO devices(id,token_hash,name,created_at) SELECT ?,?,?,? WHERE EXISTS(${eligible})`).bind(input.deviceId, tokenHash, name, now, invitation.id, now),
                env.DB.prepare(`INSERT OR IGNORE INTO memberships(group_id,device_id,role) SELECT ?,?,? WHERE EXISTS(${eligible}) AND EXISTS(SELECT 1 FROM devices WHERE id=? AND token_hash=?)`).bind(invitation.group_id, input.deviceId, invitation.role, invitation.id, now, input.deviceId, tokenHash),
                env.DB.prepare(`UPDATE invitations SET consumed_device_id=?,consumed_at=? WHERE id=? AND consumed_device_id IS NULL AND revoked_at IS NULL AND expires_at>? AND EXISTS(SELECT 1 FROM groups WHERE id=invitations.group_id AND revoked_at IS NULL) AND EXISTS(SELECT 1 FROM memberships m JOIN devices d ON d.id=m.device_id WHERE m.group_id=invitations.group_id AND m.device_id=? AND m.revoked_at IS NULL AND d.token_hash=?)`).bind(input.deviceId, now, invitation.id, now, input.deviceId, tokenHash),
            ]);
        }
        const result = await env.DB.prepare(`SELECT d.id,d.token_hash,d.name,d.avatar_version,m.role,m.group_id,g.name AS group_name 
            FROM devices d 
            JOIN memberships m ON m.device_id=d.id 
            JOIN groups g ON g.id=m.group_id 
            JOIN invitations i ON i.group_id=g.id 
            WHERE i.id=? 
            AND i.consumed_device_id=d.id 
            AND i.revoked_at IS NULL 
            AND d.id=? 
            AND d.token_hash=? 
            AND m.revoked_at IS NULL 
            AND g.revoked_at IS NULL`).bind(invitation.id, input.deviceId, tokenHash).first<Device & {
            role: 'owner' | 'member';
            group_id: string;
            group_name: string;
        }>();
        if (!result) {
            fail('Invitation consumed or membership revoked', 409);
        }
        return json({
            profile: profile(result, {
                device_id: result.id, group_id: result.group_id, role: result.role
            }), group: { id: result.group_id, name: result.group_name }, role: result.role
        });
    }
    if (!path.startsWith('/api/group')) {
        return null;
    }
    const d = await device(request, env), m = await requireMember(env, d.id);
    if (path === '/api/group') {
        if (request.method === 'GET') {
            // The caller, group metadata, roster, locations and trails share one SQLite snapshot.
            const cursors = trailCursors(new URL(request.url).searchParams.get('trailSince'));
            const [roster, trailRows] = await env.DB.batch<any>([env.DB.prepare(`
    SELECT g.id AS group_id,g.name AS group_name,g.meeting_lat,g.meeting_lon,
      g.meeting_label,g.meeting_updated_at,g.meeting_updated_by,caller.role AS caller_role,
      d.id AS member_device_id,d.name,d.avatar_version,s.*
    FROM groups g
    JOIN memberships caller ON caller.group_id=g.id AND caller.device_id=? AND caller.revoked_at IS NULL
    JOIN memberships member ON member.group_id=g.id AND member.revoked_at IS NULL
    JOIN devices d ON d.id=member.device_id
    LEFT JOIN sessions s ON s.device_id=d.id AND s.group_id=g.id
      AND s.audience='group' AND s.ended=0 AND s.expires_at>?
    WHERE g.id=? AND g.revoked_at IS NULL ORDER BY d.created_at,d.id
   `).bind(d.id, now, m.group_id), env.DB.prepare(`
    SELECT s.device_id,p.seq,p.lat,p.lon,p.observed_at
    FROM sessions s
    JOIN groups g ON g.id=s.group_id AND g.revoked_at IS NULL
    JOIN memberships caller ON caller.group_id=g.id AND caller.device_id=? AND caller.revoked_at IS NULL
    JOIN memberships member ON member.group_id=g.id AND member.device_id=s.device_id AND member.revoked_at IS NULL
    JOIN session_points p ON p.session_id=s.id
    LEFT JOIN json_each(?) c ON c.key=s.device_id AND json_extract(c.value,'$[0]')=s.expires_at
    WHERE g.id=? AND s.audience='group' AND s.ended=0 AND s.expires_at>? AND s.trail<>'off'
      AND ${trailWindowSQL('s', 'p')} AND p.seq>COALESCE(json_extract(c.value,'$[1]'),0)
    ORDER BY s.device_id,p.seq
   `).bind(d.id, JSON.stringify(cursors), m.group_id, now, now)]);
            const trails = new Map<string, TrailPoint[]>();
            for (const p of trailRows.results) {
                trails.set(p.device_id, [...trails.get(p.device_id) ?? [], [p.seq, p.lat, p.lon, p.observed_at]]);
            }
            const g = roster.results[0];
            if (!g) {
                fail('Group unavailable', 403);
            }
            return json({
                id: m.group_id, name: g.group_name, role: g.caller_role,
                meetingPoint: g.meeting_lat === null ? null : {
                    lat: g.meeting_lat, lon: g.meeting_lon, label: g.meeting_label, updatedAt: g.meeting_updated_at, updatedBy: g.meeting_updated_by
                },
                members: roster.results.map(row => ({
                    deviceId: row.member_device_id, name: row.name, avatarVersion: row.avatar_version, sharing: row.expires_at ? {
                        ...sharing(row as Session, now),
                        trail: trailOutput(row.trail, row.ended, trails.get(row.member_device_id) ?? [], cursors[row.member_device_id]?.[0] !== row.expires_at, now)
                    } : null
                }))
            });
        }
        if (request.method === 'DELETE') {
            await requireMember(env, d.id, true);
            await env.DB.prepare('UPDATE groups SET revoked_at=? WHERE id=? AND revoked_at IS NULL').bind(now, m.group_id).run();
            return empty();
        }
    }
    if (path === '/api/group/invitations') {
        await requireMember(env, d.id, true);
        if (request.method === 'POST') {
            const id = crypto.randomUUID(), token = secret(), expiresAt = now + 86400000;
            const r = await env.DB.prepare(`INSERT INTO invitations(id,group_id,token_hash,role,expires_at) SELECT ?,?,?,'member',? 
            WHERE EXISTS(SELECT 1 
            FROM memberships m 
            JOIN groups g ON g.id=m.group_id 
            WHERE m.device_id=? 
            AND m.group_id=? 
            AND m.role='owner' 
            AND m.revoked_at IS NULL 
            AND g.revoked_at IS NULL)`).bind(id, m.group_id, await hash(token), expiresAt, d.id, m.group_id).run();
            if (!r.meta.changes) {
                fail('Membership revoked', 403);
            }
            return json(invitationOutput(id, token, expiresAt, request.url), 201);
        }
        if (request.method === 'GET') {
            const rows = await env.DB.prepare('SELECT id,expires_at,consumed_at,revoked_at FROM invitations WHERE group_id=? ORDER BY expires_at').bind(m.group_id).all<any>();
            return json(rows.results.map(i => ({
                id: i.id, expiresAt: i.expires_at, consumedAt: i.consumed_at, revokedAt: i.revoked_at
            })));
        }
    }
    const invitationMatch = path.match(/^\/api\/group\/invitations\/([^/]+)$/);
    if (invitationMatch && request.method === 'DELETE') {
        await requireMember(env, d.id, true);
        await env.DB.prepare('UPDATE invitations SET revoked_at=? WHERE id=? AND group_id=? AND revoked_at IS NULL').bind(now, invitationMatch[1], m.group_id).run();
        return empty();
    }
    const avatarMatch = path.match(/^\/api\/group\/members\/([^/]+)\/avatar$/);
    if (avatarMatch && request.method === 'GET') {
        return photo(await env.DB.prepare(`SELECT d.avatar 
            FROM devices d 
            JOIN memberships target ON target.device_id=d.id 
            JOIN memberships caller ON caller.group_id=target.group_id 
            JOIN groups g ON g.id=target.group_id 
            WHERE d.id=? 
            AND caller.device_id=? 
            AND target.revoked_at IS NULL 
            AND caller.revoked_at IS NULL 
            AND g.revoked_at IS NULL`).bind(avatarMatch[1], d.id).first<Device>());
    }
    const memberMatch = path.match(/^\/api\/group\/members\/([^/]+)$/);
    if (memberMatch && request.method === 'DELETE') {
        await requireMember(env, d.id, true);
        if (memberMatch[1] === d.id) {
            fail('Owner cannot remove self', 409);
        }
        await env.DB.prepare('UPDATE memberships SET revoked_at=? WHERE group_id=? AND device_id=? AND revoked_at IS NULL').bind(now, m.group_id, memberMatch[1]).run();
        return empty();
    }
    if (path === '/api/group/membership' && request.method === 'DELETE') {
        if (m.role === 'owner') {
            fail('Owner cannot leave; delete the group instead', 409);
        }
        await env.DB.prepare('UPDATE memberships SET revoked_at=? WHERE group_id=? AND device_id=? AND revoked_at IS NULL').bind(now, m.group_id, d.id).run();
        return empty();
    }
    if (path === '/api/group/meeting-point') {
        if (request.method === 'PUT') {
            const input = await body(request);
            if (!coordinates(input)) {
                fail('Invalid meeting point', 400);
            }
            const label = text(input.label, 100);
            const r = await env.DB.prepare(`UPDATE groups 
            SET meeting_lat=?,meeting_lon=?,meeting_label=?,meeting_updated_at=?,meeting_updated_by=? 
            WHERE id=? 
            AND revoked_at IS NULL 
            AND EXISTS(SELECT 1 
            FROM memberships 
            WHERE group_id=groups.id 
            AND device_id=? 
            AND revoked_at IS NULL)`).bind(input.lat, input.lon, label, now, d.id, m.group_id, d.id).run();
            if (!r.meta.changes) {
                fail('Membership revoked', 403);
            }
            return json({
                lat: input.lat, lon: input.lon, label, updatedAt: now, updatedBy: d.id
            });
        }
        if (request.method === 'DELETE') {
            await env.DB.prepare(`UPDATE groups 
            SET meeting_lat=NULL,meeting_lon=NULL,meeting_label=NULL,meeting_updated_at=NULL,meeting_updated_by=NULL 
            WHERE id=? 
            AND revoked_at IS NULL 
            AND EXISTS(SELECT 1 
            FROM memberships 
            WHERE group_id=groups.id 
            AND device_id=? 
            AND revoked_at IS NULL)`).bind(m.group_id, d.id).run();
            return empty();
        }
    }
    fail('Not found', 404);
}
