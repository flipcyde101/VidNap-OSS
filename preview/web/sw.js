import {SHELL_ASSETS,isShellRequest} from './offline-policy.mjs';
const CACHE='vidnap-ui-preview-1';
self.addEventListener('install',event=>event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(SHELL_ASSETS)).then(()=>self.skipWaiting())));
self.addEventListener('activate',event=>event.waitUntil(self.clients.claim()));
self.addEventListener('fetch',event=>{
 if(!isShellRequest(event.request,self.location.origin))return;
 event.respondWith(fetch(event.request).catch(()=>caches.open(CACHE).then(cache=>cache.match(new URL(event.request.url).pathname))));
});
