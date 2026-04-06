import { createReadStream, existsSync } from 'node:fs';
import { stat } from 'node:fs/promises';
import { createServer } from 'node:http';
import { extname, join, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = resolve(__filename, '..');
const distDir = join(__dirname, 'dist');

const port = Number(process.env.PORT ?? 4173);
const host = process.env.HOST ?? '0.0.0.0';

const mimeTypes = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
};

function isSafePath(pathname) {
  const normalizedPath = normalize(pathname).replace(/^\/+/, '');
  const resolvedPath = resolve(distDir, normalizedPath);
  return resolvedPath.startsWith(distDir);
}

function sendFile(res, filepath) {
  const ext = extname(filepath).toLowerCase();
  const contentType = mimeTypes[ext] ?? 'application/octet-stream';

  res.writeHead(200, {
    'Content-Type': contentType,
    'Cache-Control': ext === '.html' ? 'no-cache' : 'public, max-age=31536000, immutable',
  });

  createReadStream(filepath).pipe(res);
}

const server = createServer(async (req, res) => {
  try {
    if (!existsSync(distDir)) {
      res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('dist directory not found. Run "npm run build" first.');
      return;
    }

    const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);
    const pathname = url.pathname;

    if (!isSafePath(pathname)) {
      res.writeHead(400, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Invalid path');
      return;
    }

    const normalizedPath = normalize(pathname).replace(/^\/+/, '');
    const requestedPath = join(distDir, normalizedPath || 'index.html');

    if (existsSync(requestedPath)) {
      const info = await stat(requestedPath);
      if (info.isFile()) {
        sendFile(res, requestedPath);
        return;
      }
    }

    const spaFallbackPath = join(distDir, 'index.html');
    sendFile(res, spaFallbackPath);
  } catch {
    res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Internal server error');
  }
});

server.listen(port, host, () => {
  console.log(`SER9 web server running at http://${host}:${port}`);
});
