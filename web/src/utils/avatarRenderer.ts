// TypeScript mirror of the Solidity character avatar layers in Series9IdentityRenderer.sol.
// Used by the AvatarBuilder UI to render a live, off-chain preview matching the on-chain SVG.
// Coordinates and color palettes are kept in sync with the Solidity implementation.

export type AvatarConfig = {
  skinTone: number
  hairStyle: number
  hairColor: number
  eyes: number
  mouth: number
  outfit: number
  accessory: number
  background: number
}

export const AVATAR_SLOTS = [
  'skinTone',
  'hairStyle',
  'hairColor',
  'eyes',
  'mouth',
  'outfit',
  'accessory',
  'background',
] as const

export type AvatarSlot = (typeof AVATAR_SLOTS)[number]

export const AVATAR_OPTIONS: Record<AvatarSlot, readonly string[]> = {
  skinTone: ['Light', 'Tan', 'Brown', 'Dark', 'Olive', 'Pink', 'Alien', 'Robot'],
  hairStyle: ['Bald', 'Short', 'Long', 'Ponytail', 'Bun', 'Curly', 'Mohawk', 'Hat'],
  hairColor: ['Black', 'Brown', 'Blonde', 'Red', 'Gray', 'White', 'Blue', 'Purple'],
  eyes: ['Dot', 'Round', 'Sharp', 'Sleepy', 'Wink', 'Star', 'Visor', 'Closed'],
  mouth: ['Neutral', 'Smile', 'Grin', 'Open', 'Tongue', 'Frown', 'Smirk', 'Heh'],
  outfit: ['Tee', 'Hoodie', 'Suit', 'Tank', 'Jacket', 'Dress', 'Armor', 'Bare'],
  accessory: ['None', 'Glasses', 'Sunglasses', 'Earring', 'Necklace', 'Mask', 'Headphones', 'Crown'],
  background: ['Solid', 'Gradient', 'Stripes', 'Dots', 'Grid', 'Starfield', 'Rays', 'Cosmic'],
}

export const MAX_AVATAR_SLOT_OPTION = 7

export const DEFAULT_AVATAR_CONFIG: AvatarConfig = {
  skinTone: 0,
  hairStyle: 0,
  hairColor: 0,
  eyes: 0,
  mouth: 0,
  outfit: 0,
  accessory: 0,
  background: 0,
}

// ─────────────────── Palettes (mirror Solidity) ───────────────────

const HUE_PALETTE: readonly string[][] = [
  // variant 0 (primary)
  ['#e74c3c', '#e67e22', '#f1c40f', '#2ecc71', '#1abc9c', '#3498db', '#6c5ce7', '#9b59b6', '#e84393', '#fd79a8', '#00cec9', '#0984e3', '#fdcb6e', '#55efc4', '#a29bfe', '#dfe6e9'],
  // variant 1 (dark)
  ['#c0392b', '#d35400', '#f39c12', '#27ae60', '#16a085', '#2980b9', '#5b4cde', '#8e44ad', '#d63384', '#e6688c', '#0097a7', '#0772c7', '#e5b825', '#45d4a8', '#8c7be6', '#b2bec3'],
  // variant 2 (light)
  ['#ff6b6b', '#feca57', '#ffeaa7', '#55efc4', '#81ecec', '#74b9ff', '#a29bfe', '#dfe6e9', '#fd79a8', '#fab1a0', '#7efff5', '#a6c5ff', '#fff3b0', '#b8f5d0', '#c8b6ff', '#f5f6fa'],
]

const SKIN_COLORS = ['#ffe0bd', '#f1c27d', '#c68642', '#8d5524', '#d4a373', '#ffc1cc', '#9ee493', '#b0bec5']
const HAIR_COLORS = ['#1a1a1a', '#6f4e37', '#f0e68c', '#c1440e', '#808080', '#f5f5f5', '#3b82f6', '#8b5cf6']
const OUTFIT_COLORS = ['#3b82f6', '#22c55e', '#1e293b', '#ef4444', '#9333ea', '#ec4899', '#94a3b8', '#64748b']

function colorFromHue(hue: number, variant: number): string {
  const h = ((hue % 256) + 256) % 256
  return HUE_PALETTE[variant % 3][h % 16]
}

// ─────────────────── Avatar layers (mirror Solidity strings) ───────────────────

function renderBackground(opt: number, hue: number): string {
  const primary = colorFromHue(hue, 0)
  const light = colorFromHue(hue, 2)

  if (opt === 0) {
    return `<rect x="24" y="62" width="88" height="88" fill="${primary}" opacity=".55"/>`
  }
  if (opt === 1) {
    return (
      `<rect x="24" y="62" width="88" height="44" fill="${light}" opacity=".55"/>` +
      `<rect x="24" y="106" width="88" height="44" fill="${primary}" opacity=".55"/>`
    )
  }
  if (opt === 2) {
    return (
      `<rect x="24" y="62" width="88" height="88" fill="${primary}" opacity=".4"/>` +
      `<rect x="24" y="74" width="88" height="6" fill="${light}" opacity=".55"/>` +
      `<rect x="24" y="100" width="88" height="6" fill="${light}" opacity=".55"/>` +
      `<rect x="24" y="126" width="88" height="6" fill="${light}" opacity=".55"/>`
    )
  }
  if (opt === 3) {
    return (
      `<rect x="24" y="62" width="88" height="88" fill="${primary}" opacity=".4"/>` +
      `<g fill="${light}" opacity=".7">` +
      `<circle cx="36" cy="74" r="2"/><circle cx="60" cy="74" r="2"/><circle cx="84" cy="74" r="2"/>` +
      `<circle cx="48" cy="92" r="2"/><circle cx="72" cy="92" r="2"/><circle cx="96" cy="92" r="2"/>` +
      `<circle cx="36" cy="110" r="2"/><circle cx="60" cy="110" r="2"/><circle cx="84" cy="110" r="2"/>` +
      `<circle cx="48" cy="128" r="2"/><circle cx="72" cy="128" r="2"/><circle cx="96" cy="128" r="2"/>` +
      `</g>`
    )
  }
  if (opt === 4) {
    return (
      `<rect x="24" y="62" width="88" height="88" fill="${primary}" opacity=".35"/>` +
      `<g stroke="${light}" stroke-opacity=".55" stroke-width=".5" fill="none">` +
      `<path d="M40 62v88M56 62v88M72 62v88M88 62v88M104 62v88M24 78h88M24 94h88M24 110h88M24 126h88M24 142h88"/>` +
      `</g>`
    )
  }
  if (opt === 5) {
    return (
      `<rect x="24" y="62" width="88" height="88" fill="#0f172a" opacity=".75"/>` +
      `<g fill="#f8fafc">` +
      `<circle cx="32" cy="70" r="1"/><circle cx="46" cy="80" r=".8"/><circle cx="58" cy="68" r="1.2"/>` +
      `<circle cx="72" cy="76" r=".9"/><circle cx="88" cy="72" r="1"/><circle cx="100" cy="84" r=".8"/>` +
      `<circle cx="40" cy="100" r=".7"/><circle cx="80" cy="108" r="1"/><circle cx="106" cy="120" r=".9"/>` +
      `<circle cx="30" cy="132" r="1"/><circle cx="64" cy="140" r=".8"/><circle cx="96" cy="144" r="1.1"/>` +
      `</g>`
    )
  }
  if (opt === 6) {
    return (
      `<rect x="24" y="62" width="88" height="88" fill="${primary}" opacity=".4"/>` +
      `<g stroke="${light}" stroke-opacity=".7" stroke-width=".7" fill="none">` +
      `<path d="M68 106L24 62M68 106L112 62M68 106L24 150M68 106L112 150M68 106L24 106M68 106L112 106M68 106L68 62M68 106L68 150"/>` +
      `</g>`
    )
  }
  return (
    `<rect x="24" y="62" width="88" height="88" fill="#1a103d" opacity=".85"/>` +
    `<circle cx="40" cy="80" r="14" fill="${primary}" opacity=".5"/>` +
    `<circle cx="90" cy="120" r="20" fill="${light}" opacity=".4"/>` +
    `<circle cx="68" cy="100" r="8" fill="#f8fafc" opacity=".25"/>`
  )
}

function renderOutfit(o: number, skin: string): string {
  const color = OUTFIT_COLORS[o]
  if (o === 0) return `<path d="M40 150 Q40 116 60 110 L76 110 Q96 116 96 150 Z" fill="${color}"/>`
  if (o === 1) {
    return (
      `<path d="M36 150 Q36 114 56 108 L80 108 Q100 114 100 150 Z" fill="${color}"/>` +
      `<path d="M52 96 Q68 90 84 96 L82 112 L54 112 Z" fill="${color}" opacity=".85"/>`
    )
  }
  if (o === 2) {
    return (
      `<path d="M40 150 Q40 116 58 110 L78 110 Q96 116 96 150 Z" fill="${color}"/>` +
      `<path d="M58 110 L68 130 L78 110 Z" fill="#f8fafc"/>` +
      `<path d="M68 112 L66 124 L68 128 L70 124 Z" fill="#ef4444"/>`
    )
  }
  if (o === 3) {
    return (
      `<path d="M48 150 Q48 118 60 112 L76 112 Q88 118 88 150 Z" fill="${color}"/>` +
      `<rect x="58" y="100" width="4" height="14" fill="${color}"/>` +
      `<rect x="74" y="100" width="4" height="14" fill="${color}"/>`
    )
  }
  if (o === 4) {
    return (
      `<path d="M36 150 Q36 116 56 110 L80 110 Q100 116 100 150 Z" fill="${color}"/>` +
      `<path d="M56 110 L60 138 L68 116 L76 138 L80 110 Z" fill="#1e293b"/>`
    )
  }
  if (o === 5) {
    return (
      `<path d="M30 150 Q34 120 60 114 L76 114 Q102 120 106 150 Z" fill="${color}"/>` +
      `<path d="M56 114 Q68 108 80 114 L78 122 L58 122 Z" fill="${color}" opacity=".7"/>`
    )
  }
  if (o === 6) {
    return (
      `<path d="M38 150 L38 116 L58 108 L78 108 L98 116 L98 150 Z" fill="${color}"/>` +
      `<path d="M50 116 L86 116 L86 140 L50 140 Z" fill="#cbd5e1" opacity=".5"/>` +
      `<circle cx="68" cy="128" r="3" fill="#fbbf24"/>`
    )
  }
  return `<path d="M48 150 Q48 120 60 114 L76 114 Q88 120 88 150 Z" fill="${skin}" opacity=".9"/>`
}

function renderBody(skinTone: number, outfit: number): string {
  const skin = SKIN_COLORS[skinTone]
  return (
    renderOutfit(outfit, skin) +
    `<rect x="62" y="86" width="12" height="10" fill="${skin}"/>` +
    `<circle cx="68" cy="80" r="22" fill="${skin}"/>`
  )
}

function renderMouth(opt: number): string {
  if (opt === 0) return '<rect x="62" y="90" width="12" height="2" rx="1" fill="#3a2a1a"/>'
  if (opt === 1) return '<path d="M60 88 Q68 96 76 88" stroke="#3a2a1a" stroke-width="1.6" fill="none" stroke-linecap="round"/>'
  if (opt === 2) {
    return (
      '<path d="M58 88 Q68 98 78 88 L78 92 Q68 100 58 92 Z" fill="#3a2a1a"/>' +
      '<rect x="60" y="90" width="16" height="2" fill="#f8fafc"/>'
    )
  }
  if (opt === 3) return '<ellipse cx="68" cy="91" rx="5" ry="4" fill="#3a2a1a"/>'
  if (opt === 4) {
    return (
      '<ellipse cx="68" cy="91" rx="6" ry="4" fill="#3a2a1a"/>' +
      '<ellipse cx="68" cy="93" rx="3" ry="2" fill="#f472b6"/>'
    )
  }
  if (opt === 5) return '<path d="M60 94 Q68 86 76 94" stroke="#3a2a1a" stroke-width="1.6" fill="none" stroke-linecap="round"/>'
  if (opt === 6) return '<path d="M60 92 Q66 88 76 90" stroke="#3a2a1a" stroke-width="1.6" fill="none" stroke-linecap="round"/>'
  return (
    '<path d="M62 88 Q60 92 64 94" stroke="#3a2a1a" stroke-width="1.4" fill="none" stroke-linecap="round"/>' +
    '<path d="M68 88 L68 94" stroke="#3a2a1a" stroke-width="1.4" stroke-linecap="round"/>' +
    '<path d="M74 88 Q76 92 72 94" stroke="#3a2a1a" stroke-width="1.4" fill="none" stroke-linecap="round"/>'
  )
}

function renderEyes(opt: number): string {
  if (opt === 0) return '<g fill="#1a1a1a"><circle cx="60" cy="78" r="1.6"/><circle cx="76" cy="78" r="1.6"/></g>'
  if (opt === 1) {
    return (
      '<g><circle cx="60" cy="78" r="2.8" fill="#1a1a1a"/><circle cx="76" cy="78" r="2.8" fill="#1a1a1a"/>' +
      '<circle cx="61" cy="77" r="1" fill="#f8fafc"/><circle cx="77" cy="77" r="1" fill="#f8fafc"/></g>'
    )
  }
  if (opt === 2) {
    return (
      '<g stroke="#1a1a1a" stroke-width="1.5" stroke-linecap="round" fill="none">' +
      '<path d="M56 78 L62 76"/><path d="M62 76 L62 80"/>' +
      '<path d="M80 78 L74 76"/><path d="M74 76 L74 80"/></g>'
    )
  }
  if (opt === 3) {
    return '<g stroke="#1a1a1a" stroke-width="1.6" stroke-linecap="round" fill="none"><path d="M56 78 Q60 80 64 78"/><path d="M72 78 Q76 80 80 78"/></g>'
  }
  if (opt === 4) {
    return (
      '<g fill="#1a1a1a"><circle cx="60" cy="78" r="2"/></g>' +
      '<path d="M72 78 Q76 78 80 78" stroke="#1a1a1a" stroke-width="1.6" stroke-linecap="round" fill="none"/>'
    )
  }
  if (opt === 5) {
    return (
      '<g fill="#fbbf24"><path d="M60 74 L61 77 L64 78 L61 79 L60 82 L59 79 L56 78 L59 77 Z"/>' +
      '<path d="M76 74 L77 77 L80 78 L77 79 L76 82 L75 79 L72 78 L75 77 Z"/></g>'
    )
  }
  if (opt === 6) {
    return '<rect x="50" y="74" width="36" height="8" rx="3" fill="#1a1a1a"/><rect x="52" y="76" width="32" height="2" fill="#38bdf8" opacity=".7"/>'
  }
  return '<g stroke="#1a1a1a" stroke-width="1.5" stroke-linecap="round" fill="none"><path d="M56 78 L64 78"/><path d="M72 78 L80 78"/></g>'
}

function renderHair(style: number, color: number): string {
  if (style === 0) return ''
  const hc = HAIR_COLORS[color]
  if (style === 1) return `<path d="M48 62 Q68 50 88 62 L88 70 Q68 60 48 70 Z" fill="${hc}"/>`
  if (style === 2) return `<path d="M46 60 Q68 48 90 60 L92 96 L84 90 L84 70 Q68 60 52 70 L52 90 L44 96 Z" fill="${hc}"/>`
  if (style === 3) {
    return (
      `<path d="M48 64 Q68 52 88 64 L88 74 Q68 64 48 74 Z" fill="${hc}"/>` +
      `<ellipse cx="92" cy="82" rx="6" ry="10" fill="${hc}"/>`
    )
  }
  if (style === 4) {
    return (
      `<circle cx="68" cy="54" r="8" fill="${hc}"/>` +
      `<path d="M50 64 Q68 56 86 64 L86 72 Q68 64 50 72 Z" fill="${hc}"/>`
    )
  }
  if (style === 5) {
    return (
      `<g fill="${hc}"><circle cx="52" cy="62" r="6"/><circle cx="62" cy="56" r="6"/><circle cx="74" cy="56" r="6"/><circle cx="84" cy="62" r="6"/><circle cx="50" cy="74" r="5"/><circle cx="86" cy="74" r="5"/></g>`
    )
  }
  if (style === 6) return `<path d="M64 50 L62 80 L74 80 L72 50 Z" fill="${hc}"/>`
  return (
    `<path d="M44 70 Q68 50 92 70 L92 78 L44 78 Z" fill="${hc}"/>` +
    `<rect x="42" y="74" width="52" height="4" fill="#1a1a1a"/>`
  )
}

function renderAccessory(opt: number): string {
  if (opt === 0) return ''
  if (opt === 1) {
    return (
      '<g stroke="#1a1a1a" stroke-width="1.4" fill="none">' +
      '<circle cx="60" cy="78" r="5"/><circle cx="76" cy="78" r="5"/>' +
      '<path d="M65 78 L71 78"/></g>'
    )
  }
  if (opt === 2) {
    return (
      '<g fill="#0f172a">' +
      '<rect x="54" y="74" width="12" height="8" rx="2"/>' +
      '<rect x="70" y="74" width="12" height="8" rx="2"/>' +
      '<rect x="66" y="77" width="4" height="2"/></g>'
    )
  }
  if (opt === 3) return '<g fill="#fbbf24"><circle cx="46" cy="86" r="2"/><circle cx="90" cy="86" r="2"/></g>'
  if (opt === 4) {
    return (
      '<path d="M52 102 Q68 116 84 102" stroke="#fbbf24" stroke-width="1.4" fill="none"/>' +
      '<circle cx="68" cy="112" r="3" fill="#ef4444"/>'
    )
  }
  if (opt === 5) return '<rect x="54" y="85" width="28" height="12" rx="3" fill="#f8fafc" opacity=".85"/>'
  if (opt === 6) {
    return (
      '<path d="M44 78 Q44 56 68 56 Q92 56 92 78" stroke="#1a1a1a" stroke-width="2.5" fill="none"/>' +
      '<rect x="40" y="76" width="10" height="14" rx="3" fill="#1a1a1a"/>' +
      '<rect x="86" y="76" width="10" height="14" rx="3" fill="#1a1a1a"/>'
    )
  }
  return (
    '<path d="M50 62 L54 50 L58 60 L62 46 L68 58 L74 46 L78 60 L82 50 L86 62 Z" fill="#fbbf24" stroke="#b45309" stroke-width=".6"/>' +
    '<circle cx="68" cy="54" r="1.5" fill="#ef4444"/>'
  )
}

/// Render a full 136x176 SVG previewing the avatar layers inside the canonical 88x88 frame at (24, 62).
export function renderAvatarSvg(config: AvatarConfig, hue: number): string {
  const primary = colorFromHue(hue, 0)
  const light = colorFromHue(hue, 2)
  const dark = colorFromHue(hue, 1)
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="22 60 92 92" width="136" height="136">` +
    `<defs>` +
    `<radialGradient id="avBg" cx="50%" cy="50%" r="80%">` +
    `<stop offset="0%" stop-color="${light}" stop-opacity=".55"/>` +
    `<stop offset="100%" stop-color="${dark}" stop-opacity="1"/>` +
    `</radialGradient>` +
    `<clipPath id="avClipPrev"><rect x="24" y="62" width="88" height="88" rx="18"/></clipPath>` +
    `</defs>` +
    `<rect x="22" y="60" width="92" height="92" rx="20" fill="${primary}" opacity=".22"/>` +
    `<rect x="24" y="62" width="88" height="88" rx="18" fill="url(#avBg)"/>` +
    `<g clip-path="url(#avClipPrev)">` +
    renderBackground(config.background, hue) +
    `<g transform="translate(0,8)">` +
    renderBody(config.skinTone, config.outfit) +
    renderMouth(config.mouth) +
    renderEyes(config.eyes) +
    renderHair(config.hairStyle, config.hairColor) +
    renderAccessory(config.accessory) +
    `</g>` +
    `</g>` +
    `<rect x="24" y="62" width="88" height="88" rx="18" fill="none" stroke="#ffffff" stroke-opacity=".22" stroke-width="1"/>` +
    `</svg>`
  )
}

export function avatarSvgDataUri(config: AvatarConfig, hue: number): string {
  const svg = renderAvatarSvg(config, hue)
  return `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`
}

export function equalConfig(a: AvatarConfig, b: AvatarConfig): boolean {
  return (
    a.skinTone === b.skinTone &&
    a.hairStyle === b.hairStyle &&
    a.hairColor === b.hairColor &&
    a.eyes === b.eyes &&
    a.mouth === b.mouth &&
    a.outfit === b.outfit &&
    a.accessory === b.accessory &&
    a.background === b.background
  )
}
