import { defineConfig, Plugin } from 'vite';

//
// A UI loaded from a file address cannot load module scripts in every web view, so the built UI uses an ordinary
// deferred script instead of a module script.
//
function classicScript(): Plugin {
    return {
        name: 'classic-script',
        enforce: 'post',
        transformIndexHtml(html: string): string {
            return html.replace(/<script type="module" crossorigin/g, '<script defer');
        },
    };
}

export default defineConfig({
    plugins: [classicScript()],
    root: 'ui',
    base: './',
    build: {
        outDir: '../dist',
        emptyOutDir: true,
        minify: false,
        rollupOptions: {
            output: {
                format: 'iife',
                entryFileNames: 'assets/main.js',
            },
        },
    },
});
