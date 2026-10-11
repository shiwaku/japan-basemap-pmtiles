// スタイル（openmaptiles-japan.json）を確認するビューア。
//   pnpm dev → http://localhost:5173/          … R2 のタイル
//              http://localhost:5173/?local    … ../work/osm/openmaptiles-japan.pmtiles（ローカルで生成したもの）
import * as maplibregl from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import { Protocol } from 'pmtiles';
// maplibre-gl 6 の Worker（ES モジュール）は Vite に Worker として扱わせないと開発サーバーで動かない
import workerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url';
import type { StyleSpecification, VectorSourceSpecification } from 'maplibre-gl';
import baseStyle from '../openmaptiles-japan.json';

maplibregl.setWorkerUrl(workerUrl);
const protocol = new Protocol();
maplibregl.addProtocol('pmtiles', protocol.tile);

const style = structuredClone(baseStyle) as unknown as StyleSpecification;
const local = new URLSearchParams(location.search).has('local');
if (local) {
  const osm = style.sources.openmaptiles as VectorSourceSpecification;
  osm.url = `pmtiles://${location.origin}/openmaptiles-japan.pmtiles`;
}
const label = document.querySelector('#src');
if (label) label.textContent = local ? 'OSM: ローカル（work/osm/）' : 'OSM: R2';

const map = new maplibregl.Map({
  container: 'map',
  style,
  center: [138.5, 37.5],
  zoom: 4.5,
  hash: true,
});
map.addControl(new maplibregl.NavigationControl());
map.showTileBoundaries = new URLSearchParams(location.search).has('tiles');
// ブラウザの開発者ツールから触れるようにする
(window as unknown as { map: maplibregl.Map }).map = map;
map.on('error', (e) => console.error('[map]', e.error?.message ?? e));
