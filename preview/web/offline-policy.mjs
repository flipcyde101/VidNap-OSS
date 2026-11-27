export const SHELL_ASSETS=['/','/index.html','/styles.css','/app.mjs','/view-model.mjs','/offline-policy.mjs','/manifest.webmanifest','/icons/icon.svg','/icons/icon-192.png','/icons/icon-512.png','/icons/apple-touch-icon.png'];
export function isShellRequest(request,origin) {
 try {const url=new URL(request.url);return request.method==='GET'&&url.origin===origin&&!url.search&&!url.username&&!url.password&&!url.pathname.startsWith('/api/')&&SHELL_ASSETS.includes(url.pathname)}catch{return false}
}
