import { readFileSync } from 'node:fs';
import { defineConfig } from 'vite';

// 地図アプリから URL で読むスタイル。GitHub Pages のルートに置く（build-style.ts が作る）
const STYLES = ['openmaptiles-japan.json', 'openmaptiles-japan-zxy.json'];

// pnpm dev で確認用ビューアを開く。開発時だけ ../work/osm（ローカルで生成したタイル）をルートで配る。
// pnpm build:viewer は GitHub Pages（shiwaku.github.io/japan-basemap-tile-pipeline/）向けに dist/ へ書き出す
export default defineConfig(({ command }) => ({
  base: command === 'build' ? '/japan-basemap-tile-pipeline/' : '/',
  publicDir: command === 'serve' ? '../work/osm' : false,
  plugins: [
    {
      name: 'emit-styles',
      apply: 'build',
      generateBundle() {
        for (const fileName of STYLES) {
          this.emitFile({ type: 'asset', fileName, source: readFileSync(fileName, 'utf8') });
        }
      },
    },
  ],
}));
