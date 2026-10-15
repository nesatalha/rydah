import { Env, HttpError, headers, json } from './core.js';
import { groups } from './groups.js';
import { profiles } from './profiles.js';
import { sessions } from './sessions.js';
export default {
    async fetch(request: Request, env: Env): Promise<Response> {
        const path = new URL(request.url).pathname;
        if (!path.startsWith('/api/')) {
            const response = await env.ASSETS.fetch(request);
            const secured = new Response(response.body, response);
            secured.headers.set('Referrer-Policy', 'no-referrer');
            return secured;
        }
        try {
            return await sessions(request, env, path) ?? await profiles(request, env, path) ?? await groups(request, env, path) ?? json({ error: 'Not found' }, 404);
        }
        catch (e) {
            if (e instanceof HttpError) {
                return json({ error: e.message }, e.status);
            }
            console.error('API database operation failed');
            return json({ error: 'Service unavailable' }, 503);
        }
    },
    async scheduled(_event: ScheduledController, env: Env): Promise<void> {
        const now = Date.now();
        await env.DB.batch([env.DB.prepare('DELETE FROM session_points WHERE session_id NOT IN (SELECT id FROM sessions WHERE ended=0 AND expires_at>?)').bind(now), env.DB.prepare('DELETE FROM sessions WHERE expires_at<=?').bind(now), env.DB.prepare('DELETE FROM invitations WHERE expires_at<=? AND consumed_device_id IS NULL').bind(now)]);
    }
};
