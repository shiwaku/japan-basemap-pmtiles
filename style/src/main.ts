// R2 のタイル（OSM・国土地理院・Mapterhorn）を重ねて見るビューア。GitHub Pages で公開する。
//   pnpm dev → http://localhost:5173/          … R2 のタイル
//              http://localhost:5173/?local    … OSM だけ ../work/osm/openmaptiles-japan.pmtiles（ローカルで生成したもの）
//              ?tiles                          … タイル境界を出す
import * as maplibregl from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import { Protocol } from 'pmtiles';
// maplibre-gl 6 の Worker（ES モジュール）は Vite に Worker として扱わせないと開発サーバーで動かない
import workerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url';
import type {
  LayerSpecification,
  RasterDEMSourceSpecification,
  StyleSpecification,
  VectorSourceSpecification,
} from 'maplibre-gl';
import osmStyle from '../openmaptiles-japan.json';
import gsiStyle from '../vendor/gsi-std.json';

const R2 = 'https://shi-works.com/pmtiles';
const params = new URLSearchParams(location.search);

maplibregl.setWorkerUrl(workerUrl);
const protocol = new Protocol();
maplibregl.addProtocol('pmtiles', protocol.tile);

// Mapterhorn は z12 以下が planet-japan、z13 以上が z6 区画ごとの 6-x-y に分かれている。
// 本家の website/examples/pmtiles と同じく、独自スキームの中でタイル番号から読むファイルを選ぶ。
// mapterhorn.shi-works.com（worker/）を通さず R2 を直接読むので、Worker が無くても表示できる
const demProtocol = new Protocol({ metadata: true, errorOnMissingTile: true });
// R2 にある z13 以上のサブピラミッド（上流の download_urls.json のうち日本域。mapterhorn.yml が写す）。
// 無い区画は R2 を読みに行かずに外す。上流で区画が増えたらここにも足す
const BUNDLES = new Set([
  '6-53-27', '6-54-25', '6-54-26', '6-54-27', '6-55-24', '6-55-25', '6-55-26', '6-55-27',
  '6-56-23', '6-56-24', '6-56-25', '6-56-26', '6-56-28', '6-57-22', '6-57-23', '6-57-24',
  '6-57-25', '6-57-26', '6-57-27', '6-58-22', '6-58-23', '6-59-27',
]);
const mapterhornTile: maplibregl.AddProtocolAction = async (req, abortController) => {
  const [z, x, y] = req.url.replace('mapterhorn://', '').split('/').map(Number) as [number, number, number];
  const name = z <= 12 ? 'planet-japan' : `6-${x >> (z - 6)}-${y >> (z - 6)}`;
  if (z > 12 && !BUNDLES.has(name)) throw new Error(`Mapterhorn: ${name} はありません`);
  const url = `pmtiles://${R2}/mapterhorn/${name}.pmtiles/${z}/${x}/${y}.webp`;
  const res = await demProtocol.tile({ ...req, url }, abortController);
  if (res.data === null) throw new Error(`Mapterhorn: z=${z} x=${x} y=${y} はありません`);
  return res as Awaited<ReturnType<maplibregl.AddProtocolAction>>;
};
maplibregl.addProtocol('mapterhorn', mapterhornTile);

const dem = (): RasterDEMSourceSpecification => ({
  type: 'raster-dem',
  tiles: ['mapterhorn://{z}/{x}/{y}'],
  encoding: 'terrarium',
  tileSize: 512,
  maxzoom: 16,
  attribution: '<a href="https://mapterhorn.com/attribution" target="_blank">© Mapterhorn</a>',
});

// --- 背景地図 -------------------------------------------------------------

type BaseId = 'osm' | 'gsi';

function baseStyle(id: BaseId): StyleSpecification {
  if (id === 'gsi') {
    // 国土地理院の配布スタイル（標準地図）のタイルの参照先だけを R2 の写しに替える
    const style = structuredClone(gsiStyle) as unknown as StyleSpecification;
    const v = style.sources.v as VectorSourceSpecification;
    v.tiles = [`pmtiles://${R2}/gsi/optimal_bvmap/optimal_bvmap-v1.pmtiles/{z}/{x}/{y}`];
    v.attribution =
      '<a href="https://github.com/gsi-cyberjapan/optimal_bvmap" target="_blank">国土地理院最適化ベクトルタイル（標準地図）</a>';
    return style;
  }
  const style = structuredClone(osmStyle) as unknown as StyleSpecification;
  if (params.has('local')) {
    (style.sources.openmaptiles as VectorSourceSpecification).url =
      `pmtiles://${location.origin}/openmaptiles-japan.pmtiles`;
  }
  return style;
}

// --- 陰影・3D 地形の状態 ----------------------------------------------------

const state = {
  base: (params.get('base') === 'gsi' ? 'gsi' : 'osm') as BaseId,
  hillshade: params.get('hillshade') !== '0',
  terrain: params.get('terrain') === '1',
};

const HILLSHADE: LayerSpecification = {
  id: 'mapterhorn-hillshade',
  type: 'hillshade',
  source: 'mapterhorn-hillshade',
  paint: {
    'hillshade-method': 'igor',
    'hillshade-exaggeration': 0.35,
    'hillshade-shadow-color': '#4a5560',
    'hillshade-highlight-color': '#ffffff',
  },
};

/** 背景のスタイルに Mapterhorn のソースと陰影を足す。陰影は最初の注記レイヤの下に入れる */
function withRelief(style: StyleSpecification): StyleSpecification {
  // 陰影と 3D 地形は別のソースにする（同じソースだと MapLibre が警告を出し、解像度も合わない）
  style.sources['mapterhorn-hillshade'] = dem();
  style.sources['mapterhorn-terrain'] = dem();
  const layer = { ...HILLSHADE, layout: { visibility: state.hillshade ? 'visible' : 'none' } } as LayerSpecification;
  const i = style.layers.findIndex((l) => l.type === 'symbol');
  style.layers.splice(i < 0 ? style.layers.length : i, 0, layer);
  if (state.terrain) style.terrain = { source: 'mapterhorn-terrain', exaggeration: 1.2 };
  else delete style.terrain;
  return style;
}

// --- 地図 -----------------------------------------------------------------

const map = new maplibregl.Map({
  container: 'map',
  style: withRelief(baseStyle(state.base)),
  center: [138.5, 37.5],
  zoom: 4.5,
  hash: 'map',
  maxPitch: 85,
  attributionControl: { compact: true },
});
map.addControl(new maplibregl.NavigationControl({ visualizePitch: true }), 'bottom-right');
map.addControl(new maplibregl.ScaleControl({ unit: 'metric' }), 'bottom-left');
map.showTileBoundaries = params.has('tiles');
// ブラウザの開発者ツールから触れるようにする
(window as unknown as { map: maplibregl.Map }).map = map;
map.on('error', (e) => {
  // Mapterhorn の無い区画（日本の外の z13 以上）は想定どおりなので出さない
  if (!String(e.error?.message ?? '').startsWith('Mapterhorn:')) console.error('[map]', e.error?.message ?? e);
});

/** 今の状態を URL の検索部分に書く（地図の位置は #map= に MapLibre が書く） */
function syncUrl() {
  const q = new URLSearchParams(location.search);
  q.set('base', state.base);
  if (state.hillshade) q.delete('hillshade');
  else q.set('hillshade', '0');
  if (state.terrain) q.set('terrain', '1');
  else q.delete('terrain');
  history.replaceState(null, '', `${location.pathname}?${q}${location.hash}`);
}

function render() {
  for (const b of document.querySelectorAll<HTMLButtonElement>('[data-base]')) {
    b.setAttribute('aria-pressed', String(b.dataset.base === state.base));
  }
  document.querySelector('#hillshade')?.setAttribute('aria-pressed', String(state.hillshade));
  document.querySelector('#terrain')?.setAttribute('aria-pressed', String(state.terrain));
  syncUrl();
}

for (const b of document.querySelectorAll<HTMLButtonElement>('[data-base]')) {
  b.addEventListener('click', () => {
    const id = b.dataset.base as BaseId;
    if (id === state.base) return;
    state.base = id;
    // 背景を丸ごと替え、Mapterhorn の陰影と 3D 地形は今の状態で足し直す
    map.setStyle(withRelief(baseStyle(id)), { diff: false });
    render();
  });
}

document.querySelector('#hillshade')?.addEventListener('click', () => {
  state.hillshade = !state.hillshade;
  map.setLayoutProperty(HILLSHADE.id, 'visibility', state.hillshade ? 'visible' : 'none');
  render();
});

document.querySelector('#terrain')?.addEventListener('click', () => {
  state.terrain = !state.terrain;
  map.setTerrain(state.terrain ? { source: 'mapterhorn-terrain', exaggeration: 1.2 } : null);
  // 立体にしたときは少し傾けて見せる。平面に戻したら真上から
  if (state.terrain && map.getPitch() < 30) map.easeTo({ pitch: 60 });
  if (!state.terrain) map.easeTo({ pitch: 0 });
  render();
});

render();
