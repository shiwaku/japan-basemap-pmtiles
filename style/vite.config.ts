import { defineConfig } from 'vite';

// pnpm dev で確認用ビューアを開く。開発時だけ ../work/osm（ローカルで生成したタイル）をルートで配る。
// pnpm build:viewer は GitHub Pages（shiwaku.github.io/japan-basemap-tile-pipeline/）向けに dist/ へ書き出す
export default defineConfig(({ command }) => ({
  base: command === 'build' ? '/japan-basemap-tile-pipeline/' : '/',
  publicDir: command === 'serve' ? '../work/osm' : false,
}));
