import test from 'node:test';
import assert from 'node:assert/strict';
let policy;
try{policy=await import('../preview/web/offline-policy.mjs')}catch(e){if(e.code!=='ERR_MODULE_NOT_FOUND')throw e;policy={}}
test('offline cache admits the public static shell',()=>assert.equal(policy.isShellRequest?.({url:'http://127.0.0.1:4000/styles.css',method:'GET'},'http://127.0.0.1:4000'),true));
for(const [url,method] of [['/api/state','GET'],['/api/media/a/0','GET'],['/api/command','POST'],['/app.mjs?private=source','GET'],['https://example.com/app.mjs','GET']]){
 test(`offline cache excludes ${method} ${url}`,()=>assert.equal(policy.isShellRequest?.({url:new URL(url,'http://127.0.0.1:4000').href,method},'http://127.0.0.1:4000'),false));
}
