// Convierte los árboles reales (montados con claude-code/testing desde hooks/arbol.test.tsx) a HTML para capturas.
// Uso: node tests/render-html.mjs <trees.tsv> <salida-dir>
// Aproximación del anfitrión: Box=flex, Text=span, Button=button, Svg=img inline. Espaciado xs=4px sm=8px md=12px.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
const [, , tsv, out] = process.argv
mkdirSync(out, { recursive: true })
const SP = { xs: 4, sm: 8, md: 12, lg: 16 }
const px = v => (v in SP ? SP[v] : Number(v) || 0) + 'px'
const esc = s => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;')
function html(n) {
  if (!n || typeof n !== 'object') return esc(n)
  const p = n.props || {}
  const kids = (n.children || []).map(html).join('')
  if (n.type === 'Box') {
    const s = ['display:flex', `flex-direction:${p.flexDirection || 'column'}`, 'box-sizing:border-box', 'min-width:0']
    if (p.gap) s.push(`gap:${px(p.gap)}`)
    if (p.padding) s.push(`padding:${px(p.padding)}`)
    if (p.paddingX) s.push(`padding-left:${px(p.paddingX)};padding-right:${px(p.paddingX)}`)
    if (p.paddingY) s.push(`padding-top:${px(p.paddingY)};padding-bottom:${px(p.paddingY)}`)
    if (p.backgroundColor) s.push(`background:${p.backgroundColor}`)
    if (p.justifyContent) s.push(`justify-content:${p.justifyContent}`)
    if (p.alignItems) s.push(`align-items:${p.alignItems}`)
    if (p.flexWrap) s.push(`flex-wrap:${p.flexWrap}`)
    if (p.width) s.push(`width:${p.width}`)
    if (p.borderStyle) s.push(`border:1px solid ${p.borderColor || '#444'};border-radius:${p.borderStyle === 'round' ? 8 : 0}px`)
    return `<div style="${s.join(';')}">${kids}</div>`
  }
  if (n.type === 'Text') {
    const s = [`color:${p.color || '#ece6f7'}`, `font-size:${p.size === 'caption' ? 12 : p.size === 'heading' ? 17 : 14}px`]
    if (p.bold || p.weight === 'semibold') s.push('font-weight:600')
    if (p.dimColor) s.push('opacity:.65')
    return `<span style="${s.join(';')}">${kids || esc(n.text ?? '')}</span>`
  }
  if (n.type === 'Button') {
    const prim = p.variant === 'primary'
    return `<button style="font:inherit;font-size:13px;color:#ece6f7;background:${prim ? '#6d3fd6' : '#241a36'};border:1px solid ${prim ? '#a78bfa' : '#3a2a58'};border-radius:6px;padding:4px 8px;cursor:pointer">${esc(p.label)}</button>`
  }
  if (n.type === 'Svg') return `<div style="width:${p.width}px;max-width:100%;line-height:0">${p.source}</div>`
  if (n.type === 'Input') return `<input placeholder="${esc(p.placeholder)}" value="${esc(p.value)}" aria-label="${esc(p.label)}" style="font:inherit;background:#150f20;color:#ece6f7;border:1px solid #3a2a58;border-radius:6px;padding:6px">`
  return kids
}
const ANCHOS = { c320: 320, c360: 360, c390: 390, c416: 416, c480: 480, centro: 1280 }
for (const l of readFileSync(tsv, 'utf8').split('\n').filter(Boolean)) {
  const [, nombre, json] = l.split('\t')
  const w = ANCHOS[nombre.split('-')[0]]
  writeFileSync(`${out}/${nombre}.html`, `<!doctype html><meta charset=utf-8><body style="margin:0;background:#0d0914;font:14px 'Segoe UI',sans-serif;width:${w}px">${html(JSON.parse(json))}`)
}
