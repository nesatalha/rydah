import { activeGroupSQL, bearer, body, coordinates, creator, cursor, device, empty, Env, fail, hash, json, photo, Device, membership, requireMember, secret, Session, sharing, TRAIL_MIN_INTERVAL_MS, trailOutput, TrailPoint, TRAILS, trailWindowSQL, validId, validSpeed, validToken } from './core.js';
export async function sessions(request: Request, env: Env, path: string): Promise<Response | null> {
    const now = Date.now();
    if (path === '/api/sessions' && request.method === 'POST') {
        await creator(request, env);
        const input = await body(request);
        if (!['device', 'simulation'].includes(input.source)) {
            fail('Invalid source', 400);
        }
        const id = crypto.randomUUID(), writeToken = secret(), readToken = secret(), expiresAt = now + 3600000;
        await env.DB.prepare('INSERT INTO sessions(id,write_hash,read_hash,source,expires_at) VALUES(?,?,?,?,?)').bind(id, await hash(writeToken), await hash(readToken), input.source, expiresAt).run();
        return json({
            id, writeToken, readToken, expiresAt
        }, 201);
    }
    if (path === '/api/me/sessions' && request.method === 'POST') {
        const d = await device(request, env), input = await body(request);
        const duration = input.durationMinutes ?? 60, trail = input.trail === undefined ? 'off' : input.trail;
        if (!validId(input.id) || !validToken(input.readToken) || !validToken(input.writeToken) || input.readToken === input.writeToken || !['viewer', 'group'].includes(input.audience) || ![30, 60, 120, 240].includes(duration) || !TRAILS.includes(trail)) {
            fail('Invalid session options or credentials', 400);
        }
        const readHash = await hash(input.readToken), writeHash = await hash(input.writeToken);
        const response = (s: Session, status = 200) => json({
            id: s.id, readToken: input.readToken, writeToken: input.writeToken, expiresAt: s.expires_at, audience: s.audience, trail: s.trail
        }, status);
        const retry = (s: Session) => {
            if (s.device_id !== d.id || s.read_hash !== readHash || s.write_hash !== writeHash || s.audience !== input.audience || s.duration_minutes !== duration || s.trail !== trail) {
                fail('Session ID or options conflict', 409);
            }
            if (s.ended || s.expires_at <= now) {
                fail('Sharing ended or expired', 410);
            }
            return response(s);
        };
        const previous = await env.DB.prepare('SELECT * FROM sessions WHERE id=?').bind(input.id).first<Session>();
        if (previous) {
            return retry(previous);
        }
        if (await env.DB.prepare('SELECT id FROM session_claims WHERE id=?').bind(input.id).first()) {
            const latest = await env.DB.prepare('SELECT * FROM sessions WHERE id=?').bind(input.id).first<Session>();
            if (latest) {
                return retry(latest);
            }
            fail('Session ID was already used', 410);
        }
        const m = input.audience === 'group' ? await requireMember(env, d.id) : await membership(env, d.id), expiresAt = now + duration * 60000;
        try {
            const results = await env.DB.batch([
                env.DB.prepare('UPDATE sessions SET ended=1,lat=NULL,lon=NULL,accuracy_m=NULL,speed_mps=NULL,speed_accuracy_mps=NULL,observed_at=NULL,received_at=NULL WHERE device_id=? AND ended=0 AND expires_at<=?').bind(d.id, now),
                env.DB.prepare(`INSERT INTO sessions(id,write_hash,read_hash,source,expires_at,device_id,group_id,audience,duration_minutes,trail) SELECT ?,?,?,'device',?,?,?,?,?,?
            WHERE NOT EXISTS(SELECT 1 
            FROM session_claims 
            WHERE id=?) 
            AND (? IS NULL OR EXISTS(SELECT 1 
            FROM memberships m 
            JOIN groups g ON g.id=m.group_id 
            WHERE m.device_id=? 
            AND m.group_id=? 
            AND m.revoked_at IS NULL 
            AND g.revoked_at IS NULL))`).bind(input.id, writeHash, readHash, expiresAt, d.id, input.audience === 'group' ? m!.group_id : null, input.audience, duration, trail, input.id, m?.group_id ?? null, d.id, m?.group_id ?? null),
                env.DB.prepare('INSERT OR IGNORE INTO session_claims(id,device_id) SELECT id,device_id FROM sessions WHERE id=? AND device_id=?').bind(input.id, d.id),
            ]);
            if (!results[1].meta.changes) {
                const latest = await env.DB.prepare('SELECT * FROM sessions WHERE id=?').bind(input.id).first<Session>();
                if (latest) {
                    return retry(latest);
                }
                fail('Session ID used or membership revoked', 409);
            }
        }
        catch (e) {
            if ((e as any).status) {
                throw e;
            }
            const latest = await env.DB.prepare('SELECT * FROM sessions WHERE id=?').bind(input.id).first<Session>();
            if (latest) {
                return retry(latest);
            }
            fail('An active session already exists', 409);
        }
        const row = await env.DB.prepare('SELECT * FROM sessions WHERE id=?').bind(input.id).first<Session>();
        if (!row || row.ended) {
            fail('Session ended or unavailable', 410);
        }
        return response(row, 201);
    }
    const match = path.match(/^\/api\/sessions\/([^/]+)(\/(location|avatar))?$/);
    if (!match) {
        return null;
    }
    const writing = (request.method === 'PUT' && match[3] === 'location') || (request.method === 'DELETE' && !match[3]);
    const token = bearer(request);
    let row = await env.DB.prepare('SELECT * FROM sessions WHERE id=?').bind(match[1]).first<Session>();
    if (!row || !token || await hash(token) !== (writing ? row.write_hash : row.read_hash)) {
        fail('Unauthorized', 401);
    }
    if (row.expires_at <= now) {
        fail('Sharing expired', 410);
    }
    if (request.method === 'GET' && !match[3]) {
        // Query identity and location under the same active membership check. No group fields reach viewers.
        // The trail is read in the same batch so it never outlives the session state it is returned with.
        const since = cursor(new URL(request.url).searchParams.get('since'));
        const [identity, trail] = await env.DB.batch<any>([
            env.DB.prepare(`SELECT sessions.*,d.name AS sender_name,d.avatar_version AS sender_avatar_version FROM sessions LEFT JOIN devices d ON d.id=sessions.device_id WHERE sessions.id=? AND (sessions.audience='viewer' OR sessions.ended=1 OR ${activeGroupSQL})`).bind(row.id),
            env.DB.prepare(`SELECT p.seq,p.lat,p.lon,p.observed_at FROM session_points p JOIN sessions ON sessions.id=p.session_id WHERE p.session_id=? AND p.seq>? AND sessions.ended=0 AND sessions.expires_at>? AND sessions.trail<>'off' AND (sessions.audience='viewer' OR ${activeGroupSQL}) AND ${trailWindowSQL('sessions', 'p')} ORDER BY p.seq LIMIT 2000`).bind(row.id, since, now, now),
        ]);
        const fresh = identity.results[0] as (Session & {
            sender_name: string | null;
            sender_avatar_version: number | null;
        }) | undefined;
        if (!fresh) {
            fail('Sharing ended', 410);
        }
        row = fresh;
        return json({
            ...sharing(row, now), source: row.source, sender: row.ended || !fresh.sender_name ? null : { name: fresh.sender_name, avatarVersion: fresh.sender_avatar_version },
            trail: trailOutput(row.trail, row.ended, trail.results.map((p: any): TrailPoint => [p.seq, p.lat, p.lon, p.observed_at]), since === 0, now)
        });
    }
    if (request.method === 'GET' && match[3] === 'avatar') {
        if (row.ended) {
            fail('Sharing ended', 410);
        }
        const avatar = await env.DB.prepare(`SELECT d.avatar FROM sessions JOIN devices d ON d.id=sessions.device_id WHERE sessions.id=? AND sessions.ended=0 AND sessions.expires_at>? AND (sessions.audience='viewer' OR ${activeGroupSQL})`).bind(row.id, now).first<Device>();
        if (!avatar) {
            const latest = await env.DB.prepare('SELECT ended FROM sessions WHERE id=?').bind(row.id).first<{
                ended: number;
            }>();
            if (latest?.ended) {
                fail('Sharing ended', 410);
            }
        }
        return photo(avatar);
    }
    if (request.method === 'DELETE' && !match[3]) {
        await env.DB.prepare('UPDATE sessions SET ended=1,lat=NULL,lon=NULL,accuracy_m=NULL,speed_mps=NULL,speed_accuracy_mps=NULL,observed_at=NULL,received_at=NULL WHERE id=?').bind(row.id).run();
        return empty();
    }
    if (request.method === 'PUT' && match[3] === 'location') {
        if (row.ended) {
            fail('Sharing ended', 410);
        }
        const p = await body(request);
        if (!coordinates(p) || !Number.isSafeInteger(p.seq) || p.seq <= 0 || !Number.isFinite(p.accuracyM) || p.accuracyM < 0 || p.accuracyM > 100000 || !Number.isSafeInteger(p.observedAt) || p.observedAt < now - 120000 || p.observedAt > now + 30000 || !validSpeed(p.speedMps) || !validSpeed(p.speedAccuracyMps)) {
            fail('Invalid location', 400);
        }
        // One transaction: the trail insert only matches when this exact update applied, and pruning keeps the chosen window.
        const [updated] = await env.DB.batch([
            env.DB.prepare(`UPDATE sessions SET seq=?,lat=?,lon=?,accuracy_m=?,speed_mps=?,speed_accuracy_mps=?,observed_at=?,received_at=? WHERE id=? AND ended=0 AND expires_at>? AND seq<? AND (observed_at IS NULL OR observed_at<=?) AND (audience='viewer' OR ${activeGroupSQL})`).bind(p.seq, p.lat, p.lon, p.accuracyM, p.speedMps ?? null, p.speedAccuracyMps ?? null, p.observedAt, now, row.id, now, p.seq, p.observedAt),
            env.DB.prepare(`INSERT OR IGNORE INTO session_points(session_id,seq,lat,lon,observed_at) SELECT id,seq,lat,lon,observed_at FROM sessions WHERE id=? AND seq=? AND received_at=? AND ended=0 AND trail<>'off' AND NOT EXISTS(SELECT 1 FROM session_points WHERE session_id=? AND observed_at>?)`).bind(row.id, p.seq, now, row.id, p.observedAt - TRAIL_MIN_INTERVAL_MS),
            env.DB.prepare(`DELETE FROM session_points WHERE session_id=? AND observed_at < ? - (SELECT CASE trail WHEN '15m' THEN 900000 WHEN '30m' THEN 1800000 END FROM sessions WHERE id=?)`).bind(row.id, now, row.id),
        ]);
        if (!updated.meta.changes) {
            const latest = await env.DB.prepare(`SELECT ended,expires_at FROM sessions WHERE id=? AND (audience='viewer' OR ${activeGroupSQL})`).bind(row.id).first<Session>();
            if (!latest || latest.ended || latest.expires_at <= Date.now()) {
                fail('Sharing ended or expired', 410);
            }
        }
        return json({ accepted: updated.meta.changes > 0 });
    }
    fail('Method not allowed', 405);
}
