#!/usr/bin/env node
// Serves ./spike over HTTPS so getUserMedia works on a phone on the same Wi-Fi.
// Self-signed cert, generated once via openssl, with the LAN IP in the SAN list.
// No dependencies.
import { createServer } from 'node:https';
import { readFileSync, existsSync, mkdirSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { networkInterfaces } from 'node:os';
import { join, extname, dirname, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT  = join(dirname(fileURLToPath(import.meta.url)), "..");
const PUB   = join(ROOT, "public");
const CERTS = join(ROOT, "certs");
const PORT  = Number(process.env.PORT) || 8443;

const lanIPs = Object.values(networkInterfaces()).flat()
  .filter(i => i && i.family === 'IPv4' && !i.internal).map(i => i.address);

if (!existsSync(join(CERTS, 'cert.pem'))) {
  mkdirSync(CERTS, { recursive: true });
  const san = ['DNS:localhost', 'IP:127.0.0.1', ...lanIPs.map(ip => `IP:${ip}`)].join(',');
  console.log('Generating a self-signed certificate for:', san);
  execFileSync('openssl', [
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '825',
    '-keyout', join(CERTS, 'key.pem'), '-out', join(CERTS, 'cert.pem'),
    '-subj', '/CN=sleeptracker-spike', '-addext', `subjectAltName=${san}`,
  ], { stdio: 'inherit' });
}

const TYPES = { '.html':'text/html; charset=utf-8', '.js':'text/javascript; charset=utf-8',
                '.json':'application/json', '.css':'text/css; charset=utf-8', '.ico':'image/x-icon' };

createServer({
  key:  readFileSync(join(CERTS, 'key.pem')),
  cert: readFileSync(join(CERTS, 'cert.pem')),
}, async (req, res) => {
  const url  = new URL(req.url, 'https://x');
  const rel  = normalize(decodeURIComponent(url.pathname)).replace(/^(\.\.[/\\])+/, '');
  const file = join(PUB, rel === '/' ? 'index.html' : rel);
  if (!file.startsWith(PUB)) { res.writeHead(403).end('forbidden'); return; }
  try {
    const body = await readFile(file);
    res.writeHead(200, { 'content-type': TYPES[extname(file)] ?? 'application/octet-stream',
                         'cache-control': 'no-store' });
    res.end(body);
  } catch {
    res.writeHead(404, { 'content-type': 'text/plain' }).end('not found');
  }
}).listen(PORT, '0.0.0.0', () => {
  console.log(`\n  Local   https://localhost:${PORT}`);
  for (const ip of lanIPs) console.log(`  Phone   https://${ip}:${PORT}`);
  console.log('\n  Self-signed, so the phone will warn once:');
  console.log('  Safari → Show Details → visit this website.  Chrome → Advanced → Proceed.\n');
});
