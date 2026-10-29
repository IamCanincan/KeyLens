/* 这版界面要用的 MD3E 元素清单。少 import 一个，标签就会静默降级成未知元素
   （什么都不画），所以这份清单就是"用了哪些组件"的唯一答案。
   刻意不引 barrel（@materialwebunofficial/md3e-web 的 index 会把 46 个全拖进来，
   实测 2962 KB，内联进单文件页面不可接受）。 */
import '@materialwebunofficial/md3e-web/components/md-top-app-bar.js';
import '@materialwebunofficial/md3e-web/components/md-navigation-bar.js';
import '@materialwebunofficial/md3e-web/components/md-card.js';
import '@materialwebunofficial/md3e-web/components/md-list.js';
import '@materialwebunofficial/md3e-web/components/md-button.js';
import '@materialwebunofficial/md3e-web/components/md-icon-button.js';
import '@materialwebunofficial/md3e-web/components/md-switch.js';
import '@materialwebunofficial/md3e-web/components/md-text-field.js';
import '@materialwebunofficial/md3e-web/components/md-select.js';
import '@materialwebunofficial/md3e-web/components/md-chip.js';
import '@materialwebunofficial/md3e-web/components/md-dialog.js';
import '@materialwebunofficial/md3e-web/components/md-menu.js';
import '@materialwebunofficial/md3e-web/components/md-snackbar.js';
import '@materialwebunofficial/md3e-web/components/md-tooltip.js';
import '@materialwebunofficial/md3e-web/components/md-tabs.js';
import '@materialwebunofficial/md3e-web/components/md-expansion-panel.js';
import '@materialwebunofficial/md3e-web/components/md-divider.js';
import '@materialwebunofficial/md3e-web/components/md-badge.js';
import '@materialwebunofficial/md3e-web/components/md-loading-indicator.js';
import '@materialwebunofficial/md3e-web/components/md-search-bar.js';
import '@materialwebunofficial/md3e-web/components/md-date-picker.js';
