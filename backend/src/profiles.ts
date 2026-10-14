import { body, bytes, device, Device, empty, Env, fail, hash, json, membership, profile, text, validId, validToken } from './core.js';
export async function profiles(request: Request, env: Env, path: string): Promise<Response | null> {
    if (path === '/api/devices' && request.method === 'POST') {
        // Self-registration lets a device share a private link without joining a group.
        const input = await body(request);
        const name = text(input.name, 60);
        if (!validId(input.deviceId) || !validToken(input.deviceToken)) {
            fail('Invalid device credentials', 400);
        }
        const tokenHash = await hash(input.deviceToken);
        const inserted = await env.DB.prepare('INSERT OR IGNORE INTO devices(id,token_hash,name,created_at) VALUES(?,?,?,?)').bind(input.deviceId, tokenHash, name, Date.now()).run();
        const d = await env.DB.prepare('SELECT id,token_hash,name,avatar_version FROM devices WHERE id=?').bind(input.deviceId).first<Device>();
        if (!d || d.token_hash !== tokenHash) {
            fail('Device credentials conflict', 409);
        }
        return json(profile(d, await membership(env, d.id)), inserted.meta.changes ? 201 : 200);
    }
    if (path !== '/api/me' && path !== '/api/me/avatar') {
        return null;
    }
    const d = await device(request, env);
    if (path === '/api/me') {
        if (request.method === 'GET') {
            return json(profile(d, await membership(env, d.id)));
        }
        if (request.method === 'PUT') {
            const name = text((await body(request)).name, 60);
            await env.DB.prepare('UPDATE devices SET name=? WHERE id=?').bind(name, d.id).run();
            d.name = name;
            return json(profile(d, await membership(env, d.id)));
        }
    }
    else {
        if (request.method === 'PUT') {
            if (request.headers.get('Content-Type')?.split(';')[0] !== 'image/png') {
                fail('PNG required', 400);
            }
            let png: Uint8Array;
            try {
                png = await bytes(request, 65536);
            }
            catch (e) {
                if ((e as any).status === 413) {
                    fail('Avatar exceeds 65536 bytes', 400);
                }
                throw e;
            }
            const signature = [137, 80, 78, 71, 13, 10, 26, 10];
            const v = new DataView(png.buffer, png.byteOffset, png.byteLength);
            if (png.length < 33 || !signature.every((b, i) => png[i] === b) || v.getUint32(8) !== 13 || String.fromCharCode(...png.slice(12, 16)) !== 'IHDR' || v.getUint32(16) !== 128 || v.getUint32(20) !== 128) {
                fail('Avatar must be a 128 by 128 PNG', 400);
            }
            const updated = await env.DB.prepare('UPDATE devices SET avatar=?,avatar_version=avatar_version+1 WHERE id=? RETURNING avatar_version').bind(png, d.id).first<{
                avatar_version: number;
            }>();
            return json({ avatarVersion: updated!.avatar_version });
        }
        if (request.method === 'DELETE') {
            await env.DB.prepare('UPDATE devices SET avatar=NULL,avatar_version=avatar_version+1 WHERE id=?').bind(d.id).run();
            return empty();
        }
    }
    fail('Method not allowed', 405);
}
