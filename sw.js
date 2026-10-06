const CACHE='gestao-frota-shell-v8';
self.addEventListener('install',event=>{
 self.skipWaiting();
 event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(['/manifest.webmanifest','/icon.svg'])).catch(()=>{}));
});
self.addEventListener('activate',event=>{
 event.waitUntil((async()=>{
  const keys=await caches.keys();
  await Promise.all(keys.map(key=>caches.delete(key)));
  await self.clients.claim();
 })());
});
self.addEventListener('fetch',event=>{
 if(event.request.method!=='GET')return;
 const url=new URL(event.request.url);
 if(url.origin===self.location.origin&&(event.request.mode==='navigate'||url.pathname==='/'||url.pathname==='/index.html'||url.pathname==='/sw.js')){
  event.respondWith(fetch(event.request,{cache:'no-store'}).catch(()=>caches.match(event.request)));
  return;
 }
 if(url.origin===self.location.origin){
  event.respondWith(fetch(event.request,{cache:'no-store'}).then(response=>{
   if(response&&response.ok){const copy=response.clone();caches.open(CACHE).then(cache=>cache.put(event.request,copy))}
   return response;
  }).catch(()=>caches.match(event.request)));
 }
});