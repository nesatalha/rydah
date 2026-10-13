import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { Miniflare } from 'miniflare';
import { readFile } from 'node:fs/promises';
import worker from '../src/index.js';
let mf: Miniflare; let db: D1Database;
const env = () => ({DB:db, CREATOR_KEY:'test-key', ASSETS:{fetch:async()=>new Response('asset')}});
const call = (path:string, method='GET', token='', body?:unknown) => worker.fetch(new Request(`https://demo.test${path}`, {method,headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:body === undefined ? undefined:JSON.stringify(body)}), env() as any);
let current:any;
const create = async () => { const r=await call('/api/sessions','POST','test-key',{source:'simulation',durationMinutes:60}); assert.equal(r.status,201); current=await r.json(); return current; };
const upload=(s:any, seq=1, observedAt=Date.now(),lat=41) => call(`/api/sessions/${s.id}/location`,'PUT',s.writeToken,{seq,lat,lon:29,accuracyM:8,observedAt});
before(async()=> {mf=new Miniflare({modules:true,script:'export default {fetch(){return new Response("ok")}}',d1Databases:{DB:'test'}}); db=await mf.getD1Database('DB') as unknown as D1Database; await db.exec(await readFile('migrations/0001_sessions.sql','utf8'));});
after(async()=>{await mf?.dispose();});
test('private session lifecycle uses separate read/write secrets and clears stopped coordinates',async()=>{const s=await create(); assert.notEqual(s.readToken,s.writeToken); assert.equal((await call(`/api/sessions/${s.id}`,'GET',s.writeToken)).status,401); assert.equal((await upload({...s,writeToken:s.readToken})).status,401); assert.equal((await call(`/api/sessions/${s.id}`,'GET',s.readToken)).status,200); assert.deepEqual(await (await upload(s)).json(),{accepted:true}); let data:any=await (await call(`/api/sessions/${s.id}`,'GET',s.readToken)).json(); assert.equal(data.state,'live'); assert.equal(data.location.lat,41); assert.equal((await call(`/api/sessions/${s.id}`,'DELETE',s.writeToken)).status,204); data=await (await call(`/api/sessions/${s.id}`,'GET',s.readToken)).json(); assert.equal(data.state,'ended'); assert.equal(data.location,null); assert.equal((await upload(s,2)).status,410); assert.equal((await call(`/api/sessions/${s.id}`,'DELETE',s.writeToken)).status,204);});
test('duplicate, delayed and backwards observations cannot replace a point',async()=>{const s=await create(); const now=Date.now(); await upload(s,2,now,42); assert.deepEqual(await (await upload(s,1,now,40)).json(),{accepted:false}); assert.deepEqual(await (await upload(s,3,now-1000,40)).json(),{accepted:false}); const data:any=await (await call(`/api/sessions/${s.id}`,'GET',s.readToken)).json(); assert.equal(data.location.lat,42);});
test('expired sessions and wrong credentials never disclose coordinates',async()=>{const s=await create(); await upload(s); await db.prepare('UPDATE sessions SET expires_at=? WHERE id=?').bind(Date.now()-1,s.id).run(); assert.equal((await call(`/api/sessions/${s.id}`,'GET',s.readToken)).status,410); assert.equal((await call(`/api/sessions/${s.id}`,'GET','wrong')).status,401); assert.equal((await upload(s,2)).status,410);});
test('validation rejects malformed points and computes freshness from capture time',async()=>{assert.equal((await call('/api/sessions','POST','wrong',{source:'device',durationMinutes:60})).status,401); const s=await create(); assert.equal((await upload(s,1,Date.now(),91)).status,400); assert.equal((await upload(s,1,Date.now()-121000)).status,400); for(const [age,state] of [[30000,'stale'],[70000,'offline']] as const){const t=await create(); await upload(t,1,Date.now()-age); const data:any=await (await call(`/api/sessions/${t.id}`,'GET',t.readToken)).json(); assert.equal(data.state,state);} });
test('concurrent stop and upload never resurrect coordinates',async()=>{const s=await create(); await Promise.all([upload(s),call(`/api/sessions/${s.id}`,'DELETE',s.writeToken)]); const data:any=await (await call(`/api/sessions/${s.id}`,'GET',s.readToken)).json(); assert.equal(data.state,'ended'); assert.equal(data.location,null);});
test('session expiry uses the selected duration and is persisted',async()=>{
 for(const durationMinutes of [1,30,720]) {
  const beforeRequest=Date.now();
  const response=await call('/api/sessions','POST','test-key',{source:'simulation',durationMinutes});
  const afterRequest=Date.now();
  assert.equal(response.status,201);
  const session:any=await response.json();
  assert.ok(session.expiresAt>=beforeRequest+durationMinutes*60_000);
  assert.ok(session.expiresAt<=afterRequest+durationMinutes*60_000);
  const stored=await db.prepare('SELECT expires_at FROM sessions WHERE id=?').bind(session.id).first<{expires_at:number}>();
  assert.equal(stored?.expires_at,session.expiresAt);
 }
});
test('invalid durations are rejected without creating sessions',async()=>{
 const beforeRequests=await db.prepare('SELECT COUNT(*) AS count FROM sessions').first<{count:number}>();
 for(const durationMinutes of [undefined,null,'30',true,1.5,0,-1,721,Number.MAX_SAFE_INTEGER+1,[],{}]) {
  const response=await call('/api/sessions','POST','test-key',{source:'simulation',durationMinutes});
  assert.equal(response.status,400,`durationMinutes=${JSON.stringify(durationMinutes)}`);
 }
 const afterRequests=await db.prepare('SELECT COUNT(*) AS count FROM sessions').first<{count:number}>();
 assert.equal(afterRequests?.count,beforeRequests?.count);
});
