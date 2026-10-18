// OpenFreeMap の Bright（OSM Bright 系、OpenMapTiles スキーマ）をもとに、このリポジトリのタイル向けのスタイルを作る。
//
//   pnpm build   … openmaptiles-japan.json・openmaptiles-japan-zxy.json を書き出す
//   pnpm check   … 書き出し済みのファイルが最新か確かめる（CI）
//
// 2 本はタイルの参照先だけが違う。
// - openmaptiles-japan.json     … R2 の PMTiles（pmtiles://）。利用側で pmtiles のプロトコル登録が要る
// - openmaptiles-japan-zxy.json … Worker（tiles.shi-works.com）の TileJSON。そのまま使える
//
// 変えるところ:
// - タイルの参照先をこのリポジトリが R2 に置くタイルにする
// - 地名・道路名などは日本語名（name:ja）を優先する
// - 北方領土・竹島・尖閣諸島は、タイル生成時に OSM の名前を消してある（scripts/build-osm.sh）。
//   その範囲（territories.json）にだけ国土地理院 最適化ベクトルタイルの注記を重ねる
// - 「日本海」を国土地理院の注記で出す（OSM の日本海の点は Geofabrik の japan の範囲外でタイルに入らない）
// - 北方領土の係争線（Natural Earth 由来）を消し、国土地理院の「国の所属界」を重ねる
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import type {
  ExpressionSpecification,
  FilterSpecification,
  LayerSpecification,
  LineLayerSpecification,
  StyleSpecification,
  SymbolLayerSpecification,
} from '@maplibre/maplibre-gl-style-spec';

const here = (path: string): string => fileURLToPath(new URL(path, import.meta.url));

const OUTPUTS = [
  {
    file: 'openmaptiles-japan.json',
    osm: 'pmtiles://https://shi-works.com/pmtiles/osm/openmaptiles-japan.pmtiles',
    gsi: 'pmtiles://https://shi-works.com/pmtiles/gsi/optimal_bvmap/optimal_bvmap-v1.pmtiles',
  },
  {
    file: 'openmaptiles-japan-zxy.json',
    osm: 'https://tiles.shi-works.com/osm/openmaptiles-japan.json',
    gsi: 'https://tiles.shi-works.com/gsi/optimal_bvmap/optimal_bvmap-v1.json',
  },
];

const base = JSON.parse(readFileSync(here('vendor/openfreemap-bright.json'), 'utf8')) as StyleSpecification;
const territories = JSON.parse(readFileSync(here('territories.json'), 'utf8')) as {
  type: 'Feature';
  geometry: { type: 'MultiPolygon'; coordinates: number[][][][] };
};

// 日本語名 → 現地名の順に使う
const nameJa: ExpressionSpecification = ['coalesce', ['get', 'name:ja'], ['get', 'name']];

// text-field が名前（name・name_en・name:latin など）を参照しているか
function usesName(value: unknown): boolean {
  return JSON.stringify(value ?? null).includes('name');
}

// 国境線。Bright は海上の線（maritime=1）を描かないので、日本周辺で OSM から描かれるのは
// z0–4（Natural Earth 由来）の北方領土の係争線（根室海峡〜国後水道）だけ。これを消し、
// 国土地理院の「国の所属界」（z4–7。択捉島と得撫島の間・竹島の北西・対馬海峡など）を重ねる
const NORTHERN_AREA: { type: 'Polygon'; coordinates: number[][][] } = {
  type: 'Polygon',
  coordinates: [
    [
      [144.5, 42.5],
      [150.5, 42.5],
      [150.5, 46.5],
      [144.5, 46.5],
      [144.5, 42.5],
    ],
  ],
};
const gsiCountryBoundary: LineLayerSpecification = {
  id: 'gsi_boundary_country',
  type: 'line',
  source: 'gsi',
  'source-layer': 'AdmBdry',
  minzoom: 4,
  maxzoom: 8,
  filter: ['==', ['get', 'vt_code'], 1221],
  layout: { 'line-cap': 'round', 'line-join': 'round' },
  // boundary_2 と同じ見た目
  paint: {
    'line-color': 'hsl(248,7%,66%)',
    'line-width': ['interpolate', ['linear'], ['zoom'], 3, 1, 5, 1.2, 12, 3],
  },
};

const layers: LayerSpecification[] = base.layers.flatMap((layer): LayerSpecification[] => {
  if (layer.id === 'boundary_disputed' && layer.type === 'line') {
    const filter = ['all', layer.filter, ['!', ['within', NORTHERN_AREA]]] as FilterSpecification;
    return [{ ...layer, filter }];
  }
  if (layer.id === 'boundary_2') return [layer, gsiCountryBoundary];
  if (layer.type !== 'symbol' || !usesName(layer.layout?.['text-field'])) return [layer];
  return [{ ...layer, layout: { ...layer.layout, 'text-field': nameJa } }];
});

// 国土地理院の注記。vt_code が 1000 未満のもの（地名・自然地名）で、文字があるものだけ。
// 1000 以上は記号や標高値
const annoFilter: FilterSpecification = [
  'all',
  ['has', 'vt_text'],
  ['<', ['get', 'vt_code'], 1000],
  ['within', territories.geometry],
];
// 島・集落（2xx・352）は大きめ、それ以外の自然地名は小さめ
const annoSize: ExpressionSpecification = [
  'case',
  ['any', ['<', ['get', 'vt_code'], 300], ['==', ['get', 'vt_code'], 352]],
  14,
  12,
];
const gsiAnno: SymbolLayerSpecification = {
  id: 'gsi_anno_territories',
  type: 'symbol',
  source: 'gsi',
  'source-layer': 'Anno',
  filter: annoFilter,
  layout: {
    'text-field': ['get', 'vt_text'],
    'text-font': ['Noto Sans Regular'],
    'text-size': annoSize,
    'text-max-width': 8,
    'symbol-placement': 'point',
  },
  paint: {
    'text-color': '#333',
    'text-halo-color': 'rgba(255,255,255,0.9)',
    'text-halo-width': 1.5,
  },
};

// 国土地理院の注記の「日本海」（vt_code 344、z4–6 のタイルにある）。見た目は water_name_point_label に合わせる
const gsiJapanSea: SymbolLayerSpecification = {
  id: 'gsi_anno_japan_sea',
  type: 'symbol',
  source: 'gsi',
  'source-layer': 'Anno',
  maxzoom: 7,
  filter: ['==', ['get', 'vt_text'], '日本海'],
  layout: {
    'text-field': ['get', 'vt_text'],
    'text-font': ['Noto Sans Italic'],
    'text-letter-spacing': 0.2,
    'text-size': ['interpolate', ['linear'], ['zoom'], 4, 12, 7, 15],
  },
  paint: {
    'text-color': '#495e91',
    'text-halo-color': 'rgba(255,255,255,0.7)',
    'text-halo-width': 1.5,
  },
};

const makeStyle = (osmUrl: string, gsiUrl: string): StyleSpecification => ({
  ...base,
  name: 'OpenMapTiles Japan (Bright)',
  metadata: {
    'japan-basemap:base': 'https://tiles.openfreemap.org/styles/bright',
    'japan-basemap:generated-by': 'style/build-style.ts',
  },
  sources: {
    ...base.sources,
    openmaptiles: {
      type: 'vector',
      url: osmUrl,
      attribution:
        '<a href="https://openmaptiles.org/" target="_blank">&copy; OpenMapTiles</a> ' +
        '<a href="https://www.openstreetmap.org/copyright" target="_blank">&copy; OpenStreetMap contributors</a>',
    },
    gsi: {
      type: 'vector',
      url: gsiUrl,
      attribution:
        '<a href="https://github.com/gsi-cyberjapan/optimal_bvmap" target="_blank">国土地理院最適化ベクトルタイル</a>',
    },
  },
  layers: [...layers, gsiJapanSea, gsiAnno],
});

const check = process.argv.includes('--check');
let stale = false;
for (const { file, osm, gsi } of OUTPUTS) {
  const style = makeStyle(osm, gsi);
  const text = `${JSON.stringify(style, null, 2)}
`;
  const path = here(file);
  if (check) {
    let current = '';
    try {
      current = readFileSync(path, 'utf8');
    } catch {}
    if (current !== text) {
      console.error(`${file} が古い。pnpm build で作り直してコミットする`);
      stale = true;
    } else {
      console.log(`${file} は最新`);
    }
  } else {
    writeFileSync(path, text);
    console.log(`${path} を書き出した（${style.layers.length} レイヤ）`);
  }
}
if (stale) process.exit(1);
