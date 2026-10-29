# Material Web bundle

The WebUI uses a small, tree-shaken `@material/web` 2.5.0 bundle (labs/gb
Expressive button/list/icon-button/switch, segmented buttons, dialog, outlined
text field). It is built here and **inlined** into `module/webroot/index.html`
so the manager still serves a single file and nothing is fetched at runtime.

```sh
cd tools/mwc-build
npm install
npm run build
```

The generated `index.bundle.js` is ignored; the inline block in
`module/webroot/index.html` is the artifact that ships.

`build.mjs` rewrites the GitHub-only `import ... from './x.css' with {type:
'css'}` syntax to the published `.cssresult.js` modules (esbuild cannot parse
import attributes), and removes the list item's Material Symbols checkmark
(the WebUI uses its own selection indicator and ships no icon font).

Requires a Chromium 111+ WebView (tested on WebView 156). See
[THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md).
