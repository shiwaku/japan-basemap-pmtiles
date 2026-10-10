import { defineConfig } from 'vite';

// pnpm dev で確認用ビューアを開く。開発時だけ ../work（ローカルで生成したタイル）をルートで配る
export default defineConfig(({ command }) => ({
  publicDir: command === 'serve' ? '../work' : false,
}));
