interface Env { DB:D1Database; CREATOR_KEY:string; ASSETS:Fetcher }
interface Session {id:string;write_hash:string;read_hash:string;source:string;expires_at:number;ended:number;seq:number;lat:number|null;lon:number|null;accuracy_m:number|null;observed_at:number|null;received_at:number|null}
const json=(body:unknown,status=200)=>Response.json(body,{status,headers:{'Cache-Control':'no-store','Referrer-Policy':'no-referrer'}});
const error=(message:string,status:number)=>json({error:message},status);
const bearer=(r:Request)=>r.headers.get('Authorization')?.match(/^Bearer (\S+)$/)?.[1]??'';
const secret=()=>Array.from(crypto.getRandomValues(new Uint8Array(32)),x=>x.toString(16).padStart(2,'0')).join('');
const hash=async(s:string)=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s))),x=>x.toString(16).padStart(2,'0')).join('');
export default {
 async fetch(request:Request,env:Env):Promise<Response> {
  const path=new URL(request.url).pathname;
  if(!path.startsWith('/api/')) {const response=await env.ASSETS.fetch(request);const secured=new Response(response.body,response);secured.headers.set('Referrer-Policy','no-referrer');return secured;}
  const now=Date.now(); const token=bearer(request);
  if(path==='/api/sessions' && request.method==='POST') {
   if(!env.CREATOR_KEY || !token || await hash(token)!==await hash(env.CREATOR_KEY))return error('Unauthorized',401);
   let body:any;try{body=await request.json();}catch{return error('Invalid JSON',400);}
   if(!body || !['device','simulation'].includes(body.source))return error('Invalid source',400);
   const id=crypto.randomUUID();const writeToken=secret();const readToken=secret();const expiresAt=now+3600000;
   await env.DB.prepare('INSERT INTO sessions (id,write_hash,read_hash,source,expires_at) VALUES (?,?,?,?,?)').bind(id,await hash(writeToken),await hash(readToken),body.source,expiresAt).run();
   return json({id,writeToken,readToken,expiresAt},201);
  }
  const match=path.match(/^\/api\/sessions\/([^/]+)(\/location)?$/);
  if(!match)return error('Not found',404);
  const row=await env.DB.prepare('SELECT * FROM sessions WHERE id=?').bind(match[1]).first<Session>();
  const writing=(request.method==='PUT'&&!!match[2])||(request.method==='DELETE'&&!match[2]);
  if(!row || !token || await hash(token)!==(writing?row.write_hash:row.read_hash))return error('Unauthorized',401);
  if(row.expires_at<=now)return error('Sharing expired',410);
  if(request.method==='GET'&&!match[2]) {
   const age=row.observed_at===null?null:Math.max(0,now-row.observed_at);
   const state=row.ended?'ended':age===null?'waiting':age<=20000?'live':age<=60000?'stale':'offline';
   return json({state,source:row.source,expiresAt:row.expires_at,location:row.ended||row.lat===null?null:{lat:row.lat,lon:row.lon,accuracyM:row.accuracy_m,observedAt:row.observed_at,receivedAt:row.received_at}});
  }
  if(request.method==='DELETE'&&!match[2]) {
   await env.DB.prepare('UPDATE sessions SET ended=1,lat=NULL,lon=NULL,accuracy_m=NULL,observed_at=NULL,received_at=NULL WHERE id=?').bind(row.id).run();
   return new Response(null,{status:204,headers:{'Cache-Control':'no-store'}});
  }
  if(request.method==='PUT'&&match[2]) {
   if(row.ended)return error('Sharing ended',410);
   let p:any;try{p=await request.json();}catch{return error('Invalid JSON',400);}
   if(!p || !Number.isSafeInteger(p.seq)||p.seq<=0||!Number.isFinite(p.lat)||Math.abs(p.lat)>90||!Number.isFinite(p.lon)||Math.abs(p.lon)>180||!Number.isFinite(p.accuracyM)||p.accuracyM<0||p.accuracyM>100000||!Number.isSafeInteger(p.observedAt)||p.observedAt<now-120000||p.observedAt>now+30000)return error('Invalid location',400);
   const updated=await env.DB.prepare('UPDATE sessions SET seq=?,lat=?,lon=?,accuracy_m=?,observed_at=?,received_at=? WHERE id=? AND ended=0 AND expires_at>? AND seq<? AND (observed_at IS NULL OR observed_at<=?)').bind(p.seq,p.lat,p.lon,p.accuracyM,p.observedAt,now,row.id,now,p.seq,p.observedAt).run();
   if(!updated.meta.changes){const latest=await env.DB.prepare('SELECT ended,expires_at FROM sessions WHERE id=?').bind(row.id).first<Session>();if(!latest || latest.ended || latest.expires_at<=Date.now())return error('Sharing ended or expired',410);}
   return json({accepted:updated.meta.changes>0});
  }
  return error('Method not allowed',405);
 },
 async scheduled(_event:ScheduledController,env:Env):Promise<void>{await env.DB.prepare('DELETE FROM sessions WHERE expires_at<=?').bind(Date.now()).run();}
};
