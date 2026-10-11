// OpenFreeMap の Bright（OSM Bright 系、OpenMapTiles スキーマ）をもとに、このリポジトリのタイル向けのスタイルを作る。
//
//   pnpm build   … openmaptiles-japan.json を書き出す
//   pnpm check   … 書き出し済みのファイルが最新か確かめる（CI）
//
// 変えるところ:
// - タイルの参照先をこのリポジトリが R2 に置く PMTiles にする
// - 地名・道路名などは日本語名（name:ja）を優先する
// - 北方領土・竹島は、タイル生成時に OSM の名前を消してある（scripts/build-osm.sh）。
//   その範囲（territories.json）にだけ国土地理院 最適化ベクトルタイルの注記を重ねる
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
const OUTPUT = here('openmaptiles-japan.json');

const OSM_PMTILES = 'https://shi-works.com/pmtiles/osm/openmaptiles-japan.pmtiles';
const GSI_PMTILES = 'https://shi-works.com/pmtiles/gsi/optimal_bvmap/optimal_bvmap-v1.pmtiles';

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

const style: StyleSpecification = {
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
      url: `pmtiles://${OSM_PMTILES}`,
      attribution:
        '<a href="https://openmaptiles.org/" target="_blank">&copy; OpenMapTiles</a> ' +
        '<a href="https://www.openstreetmap.org/copyright" target="_blank">&copy; OpenStreetMap contributors</a>',
    },
    gsi: {
      type: 'vector',
      url: `pmtiles://${GSI_PMTILES}`,
      attribution:
        '<a href="https://github.com/gsi-cyberjapan/optimal_bvmap" target="_blank">国土地理院最適化ベクトルタイル</a>',
    },
  },
  layers: [...layers, gsiAnno],
};

const text = `${JSON.stringify(style, null, 2)}\n`;
if (process.argv.includes('--check')) {
  const current = readFileSync(OUTPUT, 'utf8');
  if (current !== text) {
    console.error('openmaptiles-japan.json が古い。pnpm build で作り直してコミットする');
    process.exit(1);
  }
  console.log('openmaptiles-japan.json は最新');
} else {
  writeFileSync(OUTPUT, text);
  console.log(`${OUTPUT} を書き出した（${style.layers.length} レイヤ）`);
}
