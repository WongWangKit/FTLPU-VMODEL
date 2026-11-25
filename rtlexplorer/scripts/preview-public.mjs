import http from 'node:http'
import { promises as fs, createReadStream } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url))
const distDirectory = path.resolve(scriptDirectory, '..', 'dist')
const port = Number(process.env.RTL_EXPLORER_PREVIEW_PORT ?? 5181)
const mimeTypes = {
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
}

http.createServer(async (request, response) => {
  const url = new URL(request.url ?? '/', 'http://127.0.0.1')
  if (url.pathname.startsWith('/api/')) {
    response.writeHead(404, { 'Content-Type': 'application/json; charset=utf-8' })
    response.end('{"error":"Local API is not available in public preview mode."}')
    return
  }

  const requested = decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname)
  const candidate = path.resolve(distDirectory, `.${requested}`)
  const withinDist = candidate === distDirectory || candidate.startsWith(`${distDirectory}${path.sep}`)
  let filePath = withinDist ? candidate : path.join(distDirectory, 'index.html')
  try {
    if (!(await fs.stat(filePath)).isFile()) filePath = path.join(distDirectory, 'index.html')
  } catch {
    filePath = path.join(distDirectory, 'index.html')
  }

  try {
    const stat = await fs.stat(filePath)
    response.writeHead(200, {
      'Content-Type': mimeTypes[path.extname(filePath)] ?? 'application/octet-stream',
      'Content-Length': stat.size,
    })
    createReadStream(filePath).pipe(response)
  } catch {
    response.writeHead(503, { 'Content-Type': 'text/plain; charset=utf-8' })
    response.end('Run pnpm build before starting the public preview.')
  }
}).listen(port, '127.0.0.1', () => {
  console.log(`RTL Explorer public preview: http://127.0.0.1:${port}/`)
})
