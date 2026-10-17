/**
 * R2 に写した Mapterhorn の日本域を、本家 tiles.mapterhorn.com と同じ URL の形で配る。
 *
 *   GET /{z}/{x}/{y}.webp → z<=12: pmtiles/mapterhorn/planet-japan.pmtiles
 *                           z>=13: pmtiles/mapterhorn/6-{x>>(z-6)}-{y>>(z-6)}.pmtiles
 *   GET /tilejson.json    → 本家の tilejson.json と同じ項目（tiles だけこのホストに向ける）
 *
 * アーカイブは mirror-mapterhorn.sh が上流と同じファイル名で置く。z13 以上のサブピラミッドが無い所
 * （日本の外）は R2 にキーが無く 404。本家もデータの無いタイルは 404 を返す。
 * 同じアーカイブは shi-works.com/pmtiles/mapterhorn/... からも pmtiles:// で直接読める。
 */
import { EtagMismatch, PMTiles, ResolvedValueCache, type RangeResponse, type Source } from 'pmtiles'

interface Env {
  BUCKET: R2Bucket
}

const KEY_PREFIX = 'pmtiles/mapterhorn/'
const LOW = 'planet-japan'
/** これ以上のズームは z6 タイル単位のサブピラミッドを読む（上流の distribution と同じ） */
const SPLIT_ZOOM = 13
const MAX_ZOOM = 16

/**
 * タイルの Cache-Control。本家は 7 日だが、ここは更新時のパージ（CLOUDFLARE_API_TOKEN）が
 * 無くても 1 日で入れ替わるよう短めにする。
 */
const TILE_MAX_AGE = 86400

const TILE_PATH = /^\/(\d{1,2})\/(\d{1,7})\/(\d{1,7})\.webp$/

/** タイル番号から読むアーカイブを決める。上流 website/examples/pmtiles と同じ式 */
export function resolveArchive(z: number, x: number, y: number): string {
  if (z < SPLIT_ZOOM) return LOW
  const s = z - 6
  return `6-${x >> s}-${y >> s}`
}

class NotFound extends Error {}

/** R2 のオブジェクトを Range で読む PMTiles の Source。 */
class R2Source implements Source {
  constructor(
    private bucket: R2Bucket,
    private key: string,
  ) {}

  getKey(): string {
    return this.key
  }

  async getBytes(offset: number, length: number, _signal?: AbortSignal, etag?: string): Promise<RangeResponse> {
    const obj = await this.bucket.get(this.key, {
      range: { offset, length },
      onlyIf: etag ? { etagMatches: etag } : undefined,
    })
    if (!obj) throw new NotFound(this.key)
    // onlyIf が外れると本文の無い R2Object が返る。週次の更新でアーカイブが差し替わったということ
    if (!('body' in obj)) throw new EtagMismatch()
    return { data: await obj.arrayBuffer(), etag: obj.etag }
  }
}

// ヘッダとディレクトリはアイソレートが生きている間ここに残る。リクエストごとに R2 を読み直さない
const cache = new ResolvedValueCache(25, undefined)
const archives = new Map<string, PMTiles>()

function archive(env: Env, name: string): PMTiles {
  let p = archives.get(name)
  if (!p) {
    p = new PMTiles(new R2Source(env.BUCKET, `${KEY_PREFIX}${name}.pmtiles`), cache)
    archives.set(name, p)
  }
  return p
}

const CORS = { 'Access-Control-Allow-Origin': '*' }

function empty(status: number): Response {
  return new Response(null, { status, headers: CORS })
}

async function handle(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url)

  const t = TILE_PATH.exec(url.pathname)
  if (t) {
    const z = Number(t[1]), x = Number(t[2]), y = Number(t[3])
    if (z > MAX_ZOOM || x >= 2 ** z || y >= 2 ** z) return empty(404)
    const tile = await archive(env, resolveArchive(z, x, y)).getZxy(z, x, y)
    if (!tile) return empty(404)
    return new Response(tile.data, {
      headers: { ...CORS, 'Content-Type': 'image/webp', 'Cache-Control': `public, max-age=${TILE_MAX_AGE}` },
    })
  }

  if (url.pathname === '/tilejson.json') {
    // 本家の tilejson.json に合わせる。範囲は planet-japan のヘッダ、maxzoom はサブピラミッドまで含めた値
    const h = await archive(env, LOW).getHeader()
    const tilejson = {
      tilejson: '3.0.0',
      scheme: 'xyz',
      tiles: [`${url.origin}/{z}/{x}/{y}.webp`],
      attribution: "<a href='https://mapterhorn.com/attribution'>© Mapterhorn</a>",
      bounds: [h.minLon, h.minLat, h.maxLon, h.maxLat],
      center: [h.centerLon, h.centerLat, h.centerZoom],
      minzoom: 0,
      maxzoom: MAX_ZOOM,
      encoding: 'terrarium',
      tileSize: 512,
    }
    return Response.json(tilejson, {
      headers: { ...CORS, 'Cache-Control': `public, max-age=${TILE_MAX_AGE}` },
    })
  }

  return empty(404)
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        status: 204,
        headers: { ...CORS, 'Access-Control-Allow-Methods': 'GET, HEAD', 'Access-Control-Max-Age': '86400' },
      })
    }
    if (request.method !== 'GET' && request.method !== 'HEAD') return empty(405)

    // R2 を Range で読むと 1 回に 0.2 秒ほど掛かる。返したタイルはこのデータセンターの Cache API に置き、
    // 2 回目以降は R2 を読まない。更新時は mapterhorn.yml がこのホストを prefix でパージする
    const cacheKey = new Request(request.url, { method: 'GET' })
    const hit = await caches.default.match(cacheKey)
    if (hit) return hit

    let res: Response
    try {
      res = await handle(request, env)
    } catch (e) {
      if (e instanceof NotFound) return empty(404)
      console.error(e)
      return empty(500)
    }
    if (res.status === 200) ctx.waitUntil(caches.default.put(cacheKey, res.clone()))
    return res
  },
} satisfies ExportedHandler<Env>
