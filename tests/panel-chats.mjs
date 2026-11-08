// Regresion 1.9.3: ejecuta el JS REAL de la seccion Chats de panel.ps1 ($js2) con un DOM minimo simulado y comprueba que pinta la tabla
// (en 1.9.2 un comentario // se comia 'var t = ...' en la misma linea: "No se pudo leer chats: t is not defined").
// Uso: node panel-chats.mjs <ruta a panel.ps1>   -> exit 0 ok, 1 falla
import fs from 'node:fs';
const src = fs.readFileSync(process.argv[2], 'utf8');
const m = src.match(/\$js2 = @'\r?\n([\s\S]*?)\r?\n'@/);
if (!m) { console.error('no se encontro $js2'); process.exit(1); }
const els = {};
const mk = (id) => els[id] ??= { id, children: [], value: '', textContent: '', _html: '', onclick: null, onchange: null, disabled: false,
  appendChild(c) { this.children.push(c); return c; }, set innerHTML(v) { this.children = []; this._html = v; }, get innerHTML() { return this._html; } };
const document = {
  querySelector: (s) => mk(s), querySelectorAll: () => [],
  createElement: () => ({ children: [], textContent: '', value: '', appendChild(c) { this.children.push(c); return c; } }),
};
const J = { generado: '2026-11-06T00:00:00', chat_actual: 'abcdef123456', chats: [{ id_chat: 'abcdef123456', estado: 'activo confirmado', consumo: { claude_real: { valor: 1, nivel: 'VERIFICADO' }, codex: { valor: null, nivel: 'NO DISPONIBLE' }, antigravity: { valor: 2, nivel: 'OBSERVADO' } }, delegaciones: 1, errores: 0 }],
  ejecuciones_recientes: [{ fecha: '2026-11-06T00:00:00', motor: 'codex', estado: 'terminada', clase: '', id_chat: 'abcdef123456' }], ejecuciones_activas_ahora: [], resumen_general: { chats: 1, delegaciones: 1, errores: 0 } };
const fetch = () => Promise.resolve({ ok: true, json: () => Promise.resolve(J) });
new Function('document', 'location', 'fetch', m[1])(document, { protocol: 'http:' }, fetch);
mk('#ch-leer').onclick();
await new Promise((r) => setTimeout(r, 50));
const est = els['#ch-estado'].textContent;
if (!/^Leído/.test(est)) { console.error('estado: ' + est); process.exit(1); }
if (els['#ch-tabla'].children.length < 2) { console.error('la tabla de chats no se pinto'); process.exit(1); }
console.log('ok: ' + est);
