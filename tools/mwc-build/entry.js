import m3 from '@material/web/labs/gb/styles/m3.cssresult.js';

import '@material/web/labs/gb/components/button/md-gb-button.js';
import '@material/web/labs/gb/components/iconbutton/md-gb-icon-button.js';
import '@material/web/labs/gb/components/list/md-gb-list.js';
import '@material/web/labs/gb/components/list/md-gb-list-item.js';
import '@material/web/labs/gb/components/switch/md-gb-switch.js';
import '@material/web/labs/segmentedbutton/outlined-segmented-button.js';
import '@material/web/labs/segmentedbuttonset/outlined-segmented-button-set.js';
import '@material/web/dialog/dialog.js';
import '@material/web/textfield/outlined-text-field.js';

// m3.css is layered; index.html's unlayered token block overrides its colors.
try {
  if (document.adoptedStyleSheets) {
    document.adoptedStyleSheets = [...document.adoptedStyleSheets, m3];
  }
} catch (e) {
  // Older WebViews without adoptedStyleSheets fall back to the page's own CSS.
}
