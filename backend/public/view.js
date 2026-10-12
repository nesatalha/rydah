const params=new URLSearchParams(location.hash.slice(1));const id=params.get('id'),token=params.get('token');history.replaceState(null,'',location.pathname);
const el=id=>document.getElementById(id);let data=null,terminal=null,connection='',lastMap='',polling=false;
const labels={waiting:'Waiting for GPS',live:'Live location',stale:'Last known location',offline:'No recent updates',ended:'Sharing ended',expired:'Link expired',invalid:'Link unavailable'};
function render(){
 let state=terminal||data?.state||'waiting';const now=Date.now();
 if(data&&now>=data.expiresAt){terminal='expired';state='expired';data.location=null;}
 const point=terminal?null:data?.location;
 if(point&&!['ended','expired'].includes(state)){const age=Math.max(0,now-point.observedAt);state=age<=20000?'live':age<=60000?'stale':'offline';}
 el('status').className=`status ${state}`;el('status').textContent=labels[state]||state;
 el('source').textContent=data?.source==='simulation'?'SIMULATION — NOT PHONE GPS':data?.source==='device'?'DEVICE GPS • ANDROID':'';
 el('connection').textContent=connection;
 el('coords').textContent=point?`${point.lat.toFixed(5)}, ${point.lon.toFixed(5)}`:'No shared position';
 el('accuracy').textContent=point?`Accuracy ±${Math.round(point.accuracyM)} m`:'Accuracy —';
 el('captured').textContent=point?`Captured ${new Date(point.observedAt).toLocaleTimeString()}`:'Captured —';
 el('age').textContent=point?`Age ${Math.max(0,Math.floor((now-point.observedAt)/1000))} seconds`:'Age —';
 el('message').textContent=({waiting:'The sender has not uploaded a location yet.',live:'A recently captured point from this ride.',stale:'This point is aging. Waiting for a newer update.',offline:'The last point is over a minute old.',ended:'The sender stopped sharing. Coordinates have been removed.',expired:'This private session has expired. Start a new share for a fresh link.',invalid:'Open the full private link supplied by the sender.'})[state];
 el('map').hidden=!point;el('placeholder').hidden=!!point;el('external').hidden=!point;
 if(point){const marker=`${point.lat},${point.lon}`;if(marker!==lastMap){const d=.008;const bbox=[point.lon-d,point.lat-d,point.lon+d,point.lat+d].join(',');el('map').src=`https://www.openstreetmap.org/export/embed.html?bbox=${encodeURIComponent(bbox)}&layer=mapnik&marker=${encodeURIComponent(marker)}`;lastMap=marker;}el('external').href=`https://www.openstreetmap.org/?mlat=${point.lat}&mlon=${point.lon}#map=16/${point.lat}/${point.lon}`;}
 else{el('map').removeAttribute('src');el('external').removeAttribute('href');lastMap='';}
}
async function poll(){if(polling||terminal)return;polling=true;try{const response=await fetch(`/api/sessions/${encodeURIComponent(id)}`,{headers:{Authorization:`Bearer ${token}`},cache:'no-store',signal:AbortSignal.timeout(8000)});if(response.status===410){terminal='expired';data=null;}else if(response.status===401){terminal='invalid';data=null;}else if(!response.ok)throw Error('server unavailable');else{data=await response.json();connection='';if(data.state==='ended')terminal='ended';}}catch{connection='Connection interrupted. Retrying; displayed age continues to increase.';}finally{polling=false;render();}}
if(!id||!token){terminal='invalid';render();}else{poll();setInterval(poll,5000);setInterval(render,1000);}
