export interface Env {
    DB: D1Database;
    CREATOR_KEY: string;
    ASSETS: Fetcher;
}
export interface Device {
    id: string;
    token_hash: string;
    name: string;
    avatar: ArrayBuffer | null;
    avatar_version: number;
}
export interface Membership {
    group_id: string;
    device_id: string;
    role: 'owner' | 'member';
}
export interface Session {
    id: string;
    write_hash: string;
    read_hash: string;
    source: string;
    expires_at: number;
    ended: number;
    seq: number;
    lat: number | null;
    lon: number | null;
    accuracy_m: number | null;
    speed_mps: number | null;
    speed_accuracy_mps: number | null;
    observed_at: number | null;
    received_at: number | null;
    device_id: string | null;
    group_id: string | null;
    audience: 'viewer' | 'group';
    duration_minutes: number;
    trail: Trail;
}
export type Trail = 'off' | '15m' | '30m' | 'session';
export const TRAILS: Trail[] = ['off', '15m', '30m', 'session'];
export const TRAIL_MIN_INTERVAL_MS = 10000;
const TRAIL_WINDOW_MS: Record<Trail, number | null> = { off: null, '15m': 900000, '30m': 1800000, session: null };
// Points older than the window are hidden on read even before an upload prunes them. Expects `?` bound to now.
export const trailWindowSQL = (s: string, p: string) => `(${s}.trail='session' OR ${p}.observed_at >= ? - CASE ${s}.trail WHEN '15m' THEN 900000 ELSE 1800000 END)`;
export type TrailPoint = [number, number, number, number];
export function trailOutput(setting: Trail, ended: number, points: TrailPoint[], reset: boolean, now: number) {
    if (setting === 'off' || ended) {
        return null;
    }
    const window = TRAIL_WINDOW_MS[setting];
    return { setting, windowStartsAt: window === null ? null : now - window, reset, points };
}
export const cursor = (value: string | null) => {
    if (value === null || value === '') {
        return 0;
    }
    if (!/^\d{1,15}$/.test(value)) {
        fail('Invalid trail cursor', 400);
    }
    return Number(value);
};
// trailSince=<deviceId>:<expiresAt>:<seq>,... -> {deviceId: [expiresAt, seq]}; keys are client input, so no prototype.
export function trailCursors(value: string): Record<string, [number, number]> {
    const result: Record<string, [number, number]> = Object.create(null);
    if (value === '') {
        return result;
    }
    const entries = value.split(',');
    if (entries.length > 32) {
        fail('Too many trail cursors', 400);
    }
    for (const entry of entries) {
        const m = entry.match(/^([A-Za-z0-9_-]{1,128}):(\d{1,15}):(\d{1,15})$/);
        if (!m) {
            fail('Invalid trail cursor', 400);
        }
        result[m[1]] = [Number(m[2]), Number(m[3])];
    }
    return result;
}
export class HttpError extends Error {
    constructor(message: string, public status: number) {
        super(message);
    }
}
export const headers = { 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' };
export const json = (body: unknown, status = 200) => Response.json(body, { status, headers });
export const empty = () => new Response(null, { status: 204, headers });
export const bearer = (r: Request) => r.headers.get('Authorization')?.match(/^Bearer (\S+)$/)?.[1] ?? '';
export const secret = () => Array.from(crypto.getRandomValues(new Uint8Array(32)), x => x.toString(16).padStart(2, '0')).join('');
export const hash = async (s: string) => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s))), x => x.toString(16).padStart(2, '0')).join('');
export function fail(message: string, status: number): never {
    throw new HttpError(message, status);
}
export const validId = (id: unknown): id is string => typeof id === 'string' && /^[a-zA-Z0-9_-]{1,128}$/.test(id);
export const validToken = (s: unknown): s is string => typeof s === 'string' && /^[a-f0-9]{64}$/.test(s);
export function text(value: unknown, max: number): string {
    if (typeof value !== 'string' || !value.trim() || value.trim().length > max) {
        fail('Invalid name or label', 400);
    }
    return value.trim();
}
// GPS speed and its accuracy in m/s; absent or null means unknown.
export const validSpeed = (v: unknown) => v === undefined || v === null || (typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= 100);
export const coordinates = (body: any) => body && typeof body.lat === 'number' && Number.isFinite(body.lat) && Math.abs(body.lat) <= 90 && typeof body.lon === 'number' && Number.isFinite(body.lon) && Math.abs(body.lon) <= 180;
export async function bytes(request: Request, limit: number): Promise<Uint8Array> {
    const declared = request.headers.get('Content-Length');
    if (declared && Number(declared) > limit) {
        fail('Body too large', 413);
    }
    if (!request.body) {
        return new Uint8Array();
    }
    const reader = request.body.getReader();
    const chunks: Uint8Array[] = [];
    let length = 0;
    try {
        for (;;) {
            const { done, value } = await reader.read();
            if (done) {
                break;
            }
            length += value.byteLength;
            if (length > limit) {
                await reader.cancel();
                fail('Body too large', 413);
            }
            chunks.push(value);
        }
    }
    finally {
        reader.releaseLock();
    }
    const result = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) {
        result.set(chunk, offset);
        offset += chunk.byteLength;
    }
    return result;
}
export async function body(request: Request): Promise<any> {
    const raw = await bytes(request, 4096);
    try {
        const value = JSON.parse(new TextDecoder().decode(raw));
        if (!value || Array.isArray(value) || typeof value !== 'object') {
            fail('Invalid JSON object', 400);
        }
        return value;
    }
    catch (e) {
        if (e instanceof HttpError) {
            throw e;
        }
        fail('Invalid JSON', 400);
    }
}
export async function creator(request: Request, env: Env) {
    const token = bearer(request);
    if (!env.CREATOR_KEY || !token || await hash(token) !== await hash(env.CREATOR_KEY)) {
        fail('Unauthorized', 401);
    }
}
export async function device(request: Request, env: Env): Promise<Device> {
    const token = bearer(request);
    if (!token) {
        fail('Unauthorized', 401);
    }
    const row = await env.DB.prepare('SELECT id,token_hash,name,avatar_version FROM devices WHERE token_hash=?').bind(await hash(token)).first<Device>();
    if (!row) {
        fail('Unauthorized', 401);
    }
    return row;
}
export async function membership(env: Env, id: string): Promise<Membership | null> {
    return env.DB.prepare('SELECT m.group_id,m.device_id,m.role FROM memberships m JOIN groups g ON g.id=m.group_id WHERE m.device_id=? AND m.revoked_at IS NULL AND g.revoked_at IS NULL').bind(id).first<Membership>();
}
export async function requireMember(env: Env, id: string, owner = false): Promise<Membership> {
    const m = await membership(env, id);
    if (!m) {
        fail('Active group membership required', 403);
    }
    if (owner && m.role !== 'owner') {
        fail('Owner role required', 403);
    }
    return m;
}
export const profile = (d: Device, m: Membership | null) => ({
    deviceId: d.id, name: d.name, avatarVersion: d.avatar_version, groupId: m?.group_id ?? null, role: m?.role ?? null
});
export function sharing(s: Session, now = Date.now()) {
    const age = s.observed_at === null ? null : Math.max(0, now - s.observed_at);
    const state = s.ended ? 'ended' : age === null ? 'waiting' : age <= 20000 ? 'live' : age <= 60000 ? 'stale' : 'offline';
    return {
        state, expiresAt: s.expires_at, location: s.ended || s.lat === null ? null : {
            lat: s.lat, lon: s.lon, accuracyM: s.accuracy_m, speedMps: s.speed_mps ?? null, speedAccuracyMps: s.speed_accuracy_mps ?? null, observedAt: s.observed_at, receivedAt: s.received_at
        }
    };
}
export const activeGroupSQL = "EXISTS (SELECT 1 FROM memberships m JOIN groups g ON g.id=m.group_id WHERE m.device_id=sessions.device_id AND m.group_id=sessions.group_id AND m.revoked_at IS NULL AND g.revoked_at IS NULL)";
export function photo(row: Device | null) {
    if (!row?.avatar) {
        fail('Photo unavailable', 404);
    }
    return new Response(new Uint8Array(row.avatar), { headers: {
            ...headers, 'Content-Type': 'image/png', 'X-Content-Type-Options': 'nosniff'
        } });
}
