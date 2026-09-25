// The places the day moves through, drawn as flat illustrations on a 1920 × 1080 world. The
// laptop always sits in the same spot at the centre; only the room and its light change.
// Elements tagged with data-* attributes are animated per frame by demo.mjs.

const W = 1920;
const H = 1080;
/** Where the table's far edge meets the wall. */
export const TABLE_Y = 612;

const grad = (id, stops, x2 = 0, y2 = 1) =>
  `<linearGradient id="${id}" x1="0" y1="0" x2="${x2}" y2="${y2}">${stops
    .map(([offset, color, opacity = 1]) => `<stop offset="${offset}" stop-color="${color}" stop-opacity="${opacity}"/>`)
    .join('')}</linearGradient>`;
const radial = (id, stops) =>
  `<radialGradient id="${id}">${stops
    .map(([offset, color, opacity = 1]) => `<stop offset="${offset}" stop-color="${color}" stop-opacity="${opacity}"/>`)
    .join('')}</radialGradient>`;

const table = (id, top, bottom, edge) => `
  <rect x="0" y="${TABLE_Y}" width="${W}" height="${H - TABLE_Y}" fill="url(#${id}-table)"/>
  <rect x="0" y="${TABLE_Y}" width="${W}" height="3" fill="${edge}" opacity=".7"/>
  <defs>${grad(`${id}-table`, [[0, top], [1, bottom]])}</defs>
  <ellipse cx="960" cy="772" rx="560" ry="34" fill="#000" opacity=".16" filter="url(#soft)"/>`;

/** Three curls of steam over a cup whose rim is centred at (x, y). */
const steam = (x, y, color = '#fff') => [0, 1, 2]
  .map(i => `<path data-steam="${i}" d="M${x - 18 + i * 18} ${y} c -14 -30 18 -44 4 -76 c -10 -24 12 -38 6 -60" fill="none" stroke="${color}" stroke-width="7" stroke-linecap="round" opacity=".0"/>`)
  .join('');

const clock = (x, y, r, face, rim, hand) => `
  <g transform="translate(${x} ${y})">
    <circle r="${r + 8}" fill="${rim}"/>
    <circle r="${r}" fill="${face}"/>
    ${Array.from({length: 12}, (_, i) => `<rect x="-2" y="${-r + 8}" width="4" height="${i % 3 ? 8 : 14}" rx="2" fill="${hand}" opacity=".55" transform="rotate(${i * 30})"/>`).join('')}
    <rect data-clock-hour x="-4" y="${-r * 0.52}" width="8" height="${r * 0.58}" rx="4" fill="${hand}"/>
    <rect data-clock-minute x="-2.5" y="${-r * 0.8}" width="5" height="${r * 0.86}" rx="2.5" fill="${hand}"/>
    <circle r="7" fill="${hand}"/>
  </g>`;

const plant = (x, y, pot, leaf, leaf2, scale = 1) => `
  <g transform="translate(${x} ${y}) scale(${scale})">
    ${[-60, -30, 0, 28, 55, -80, 75].map((angle, i) => `<ellipse cx="0" cy="-70" rx="22" ry="62" fill="${i % 2 ? leaf2 : leaf}" transform="rotate(${angle}) translate(0 ${-10 - (i % 3) * 8})"/>`).join('')}
    <path d="M-52 -8 h104 l-12 84 a10 10 0 0 1 -10 8 h-60 a10 10 0 0 1 -10 -8 z" fill="${pot}"/>
    <rect x="-58" y="-16" width="116" height="16" rx="6" fill="${pot}" style="filter:brightness(1.08)"/>
  </g>`;

const mug = (x, base, body, band, coffee) => `
  <g transform="translate(${x} ${base})">
    <ellipse cx="0" cy="4" rx="80" ry="12" fill="#000" opacity=".12"/>
    <path d="M52 -92 a34 34 0 0 1 0 64" fill="none" stroke="${body}" stroke-width="16"/>
    <path d="M-58 -118 h116 v96 a22 22 0 0 1 -22 22 h-72 a22 22 0 0 1 -22 -22 z" fill="${body}"/>
    <rect x="-58" y="-78" width="116" height="16" fill="${band}"/>
    <ellipse cx="0" cy="-118" rx="58" ry="12" fill="${coffee}"/>
    <path d="M-58 -118 a58 12 0 0 0 116 0" fill="none" stroke="#fff" stroke-opacity=".5" stroke-width="3"/>
  </g>`;

const window = (x, y, w, h, frame, sky, inner = '') => `
  <g>
    <rect x="${x - 14}" y="${y - 14}" width="${w + 28}" height="${h + 28}" rx="10" fill="${frame}"/>
    <svg x="${x}" y="${y}" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" overflow="hidden">
      <rect width="${w}" height="${h}" fill="${sky}"/>
      ${inner}
    </svg>
    <rect x="${x + w / 2 - 6}" y="${y}" width="12" height="${h}" fill="${frame}"/>
    <rect x="${x}" y="${y + h * 0.46}" width="${w}" height="12" fill="${frame}"/>
    <rect x="${x - 30}" y="${y + h + 10}" width="${w + 60}" height="18" rx="4" fill="${frame}" style="filter:brightness(.92)"/>
  </g>`;

const ROOMS = {
  morning: () => `
    <defs>
      ${grad('m-wall', [[0, '#F7E2CB'], [1, '#EFCBA8']])}
      ${grad('m-sky', [[0, '#BFE0EE'], [0.7, '#F6E6CF'], [1, '#FBD9B5']])}
      ${grad('m-beam', [[0, '#FFF6DF', 0.5], [1, '#FFF6DF', 0]], 0.6, 1)}
      ${radial('m-sun', [[0, '#FFFBEA'], [0.35, '#FFF1C8', 0.9], [1, '#FFE7B0', 0]])}
    </defs>
    <rect width="${W}" height="${H}" fill="url(#m-wall)"/>
    ${window(1490, 116, 300, 420, '#FFF8EF', 'url(#m-sky)', `<circle data-sun cx="220" cy="120" r="150" fill="url(#m-sun)"/><path d="M0 330 q60 -40 120 -8 t140 -6 t120 10 v200 h-380z" fill="#CFE0C0"/>`)}
    <polygon data-beam points="1490,130 1790,130 1300,${TABLE_Y + 300} 700,${TABLE_Y + 300}" fill="url(#m-beam)"/>
    <rect x="130" y="450" width="420" height="14" rx="4" fill="#C9A07A"/>
    ${plant(210, 450, '#E9A987', '#86A77F', '#9DBB90', 0.62)}
    <g transform="translate(330 382)"><rect x="-26" y="0" width="52" height="68" rx="10" fill="#FFFFFF" opacity=".75"/><rect x="-26" y="30" width="52" height="38" rx="8" fill="#E6B98C"/></g>
    <g transform="translate(440 370)"><rect x="-30" y="0" width="60" height="80" rx="14" fill="#9DB6C4"/><rect x="-18" y="-14" width="36" height="16" rx="5" fill="#7F99A8"/></g>
    <path d="M500 464 c 10 40 -20 70 4 110 c 10 20 -4 30 -2 38" fill="none" stroke="#7E9E76" stroke-width="5"/>
    ${[500, 540, 580].map((y, i) => `<ellipse cx="${504 + (i % 2 ? 16 : -14)}" cy="${y}" rx="16" ry="10" fill="${i % 2 ? '#8FB184' : '#7AA06F'}" transform="rotate(${i % 2 ? 30 : -30} ${504 + (i % 2 ? 16 : -14)} ${y})"/>`).join('')}
    ${table('m', '#E2BA93', '#C99B72', '#F2D2B0')}
    ${mug(300, 790, '#FFFBF4', '#E48C68', '#6E4631')}
    ${steam(300, 650)}
    <g transform="translate(1600 792)"><ellipse cx="0" cy="0" rx="120" ry="16" fill="#000" opacity=".1"/><ellipse cx="0" cy="-8" rx="112" ry="22" fill="#FFFDF8"/><path d="M-70 -18 q70 -70 140 0 q-70 20 -140 0z" fill="#E7A95D"/><path d="M-40 -30 q40 -24 80 0" stroke="#C98642" stroke-width="5" fill="none"/></g>`,

  cafe: () => `
    <defs>
      ${grad('c-wall', [[0, '#F2E6D3'], [1, '#EBDBC2']])}
      ${grad('c-out', [[0, '#DCE8C8'], [1, '#B9CFA5']])}
      ${radial('c-glow', [[0, '#FFE6B0', 0.85], [1, '#FFE6B0', 0]])}
    </defs>
    <rect width="${W}" height="${H}" fill="url(#c-wall)"/>
    <rect x="0" y="440" width="${W}" height="${TABLE_Y - 440}" fill="#9A6A48"/>
    ${Array.from({length: 24}, (_, i) => `<rect x="${i * 80 + 38}" y="452" width="4" height="${TABLE_Y - 460}" fill="#86593A"/>`).join('')}
    <rect x="0" y="436" width="${W}" height="10" fill="#7C5134"/>
    <g>
      <g transform="translate(1320 0)"><path d="M100 560 v-300 a230 230 0 0 1 460 0 v300 z" fill="#5A3A28"/>
      <svg x="118" y="46" width="424" height="496" viewBox="0 0 424 496"><path d="M0 496 v-282 a212 212 0 0 1 424 0 v282z" fill="url(#c-out)"/>
        ${[[70, 250, 46, '#F4E3A8'], [300, 170, 60, '#FFFFFF'], [180, 330, 34, '#EACB8A'], [360, 380, 40, '#F7EFD2'], [120, 420, 28, '#FFFFFF'], [250, 280, 22, '#F4D98F']].map(([x, y, r, c], i) => `<circle data-bokeh="${i}" cx="${x}" cy="${y}" r="${r}" fill="${c}" opacity=".55"/>`).join('')}
        <path d="M0 496 v-120 q80 -50 160 -10 t160 -20 t104 10 v140z" fill="#9CB78A"/>
      </svg>
      <rect x="323" y="46" width="14" height="514" fill="#5A3A28"/>
      <rect x="80" y="552" width="500" height="20" rx="4" fill="#4A2F20"/></g>
    </g>
    ${[1500, 1780].map((x, i) => `<g><rect x="${x - 2}" y="0" width="4" height="${150 + i * 30}" fill="#3C3A36"/><circle data-lamp="${i}" cx="${x}" cy="${230 + i * 30}" r="210" fill="url(#c-glow)"/><path d="M${x - 70} ${204 + i * 30} a70 60 0 0 1 140 0 z" fill="#2F4E46"/><ellipse cx="${x}" cy="${206 + i * 30}" rx="26" ry="10" fill="#FFF3D1"/></g>`).join('')}
    <g transform="translate(140 380)"><rect width="320" height="170" rx="10" fill="#2F3431" stroke="#7C5134" stroke-width="10"/>
      ${[40, 72, 104, 136].map((y, i) => `<rect x="34" y="${y}" width="${[170, 220, 140, 190][i]}" height="8" rx="4" fill="#F1EEE6" opacity=".7"/><rect x="${260}" y="${y}" width="30" height="8" rx="4" fill="#F1EEE6" opacity=".5"/>`).join('')}</g>
    ${table('c', '#B7825A', '#976444', '#D29C71')}
    <g transform="translate(1590 790)"><ellipse cx="0" cy="0" rx="120" ry="18" fill="#000" opacity=".12"/><ellipse cx="0" cy="-6" rx="112" ry="22" fill="#F6F1E8"/><path d="M-66 -110 h132 l-12 90 a24 24 0 0 1 -24 20 h-60 a24 24 0 0 1 -24 -20 z" fill="#F9F6F0"/><path d="M60 -92 a30 30 0 0 1 0 56" fill="none" stroke="#F9F6F0" stroke-width="14"/><ellipse cx="0" cy="-110" rx="66" ry="14" fill="#C99368"/><path d="M-18 -114 q18 -14 18 4 q0 -18 18 -4 q-4 10 -18 14 q-14 -4 -18 -14z" fill="#FFF3E0"/></g>
    ${steam(1590, 660)}
    <g transform="translate(330 792)"><ellipse cx="0" cy="-4" rx="130" ry="24" fill="#F6F1E8"/><path d="M-96 -18 q20 -60 96 -64 q76 4 96 64 q-96 18 -192 0z" fill="#E3A357"/>${[-54, -18, 18, 54].map(x => `<path d="M${x} -76 q10 30 ${x > 0 ? 14 : -14} 58" stroke="#B97A3A" stroke-width="5" fill="none"/>`).join('')}</g>`,

  low: () => `
    <defs>
      ${grad('l-wall', [[0, '#CBD3DB'], [1, '#B9C3CD']])}
      ${grad('l-sky', [[0, '#E6ECF1'], [1, '#C9D4DE']])}
    </defs>
    <rect width="${W}" height="${H}" fill="url(#l-wall)"/>
    <g data-blinds>${Array.from({length: 9}, (_, i) => `<polygon points="${1000 + i * 70},0 ${1040 + i * 70},0 ${700 + i * 70},${TABLE_Y} ${660 + i * 70},${TABLE_Y}" fill="#FFFFFF" opacity=".16"/>`).join('')}</g>
    <g><rect x="1476" y="106" width="328" height="448" rx="8" fill="#E9EDF1"/><rect x="1490" y="120" width="300" height="420" fill="url(#l-sky)"/>
      ${Array.from({length: 14}, (_, i) => `<rect x="1490" y="${124 + i * 30}" width="300" height="18" rx="3" fill="#F4F6F8" opacity=".92"/>`).join('')}
      <rect x="1780" y="120" width="3" height="440" fill="#9AA6B2"/></g>
    ${clock(470, 440, 62, '#F7F9FB', '#8E99A5', '#39424C')}
    <g transform="translate(110 540)"><rect width="200" height="12" rx="3" fill="#8D98A3"/>
      ${[[8, 76, '#7D8FA3'], [30, 92, '#B3907A'], [54, 70, '#6E7F74'], [74, 86, '#A5ACB5'], [96, 64, '#8C7B9A'], [116, 80, '#728A99']].map(([x, h, c]) => `<rect x="${x}" y="${-h}" width="${x === 116 ? 26 : 20}" height="${h}" rx="3" fill="${c}"/>`).join('')}</g>
    ${table('l', '#A2ABB4', '#89929C', '#C2CAD2')}
    <g transform="translate(300 780)"><ellipse cx="0" cy="6" rx="150" ry="16" fill="#000" opacity=".12"/>${[0, 1, 2, 3].map(i => `<rect x="${-120 + i * 3}" y="${-18 - i * 14}" width="240" height="14" rx="3" fill="${i % 2 ? '#F4F6F8' : '#E4E9EE'}" transform="rotate(${i * 1.4 - 2})"/>`).join('')}<rect x="30" y="-96" width="70" height="60" fill="#F6E27A" transform="rotate(8)"/></g>
    ${mug(1600, 790, '#D9DFE5', '#7A8896', '#4F3A2E')}`,

  reset: () => `
    <defs>
      ${grad('r-wall', [[0, '#F5C08C'], [1, '#E49468']])}
      ${grad('r-sky', [[0, '#FFD493'], [0.55, '#F59A66'], [1, '#B8657A']])}
      ${radial('r-sun', [[0, '#FFF4D6'], [0.4, '#FFD08A', 0.9], [1, '#FF9D5C', 0]])}
      ${grad('r-beam', [[0, '#FFE9BE', 0.55], [1, '#FFE9BE', 0]], 1, 0.3)}
    </defs>
    <rect width="${W}" height="${H}" fill="url(#r-wall)"/>
    <polygon data-beam points="1480,180 1490,540 200,${TABLE_Y} 120,160" fill="url(#r-beam)" opacity=".7"/>
    ${window(1490, 116, 300, 420, '#FBE3C8', 'url(#r-sky)', `<circle data-sun cx="170" cy="330" r="190" fill="url(#r-sun)"/><circle cx="170" cy="330" r="46" fill="#FFF1D2"/><path d="M0 360 h40 v-60 h50 v90 h40 v-40 h60 v60 h50 v-110 h50 v160 h60 v80 h-350z" fill="#7B4B5E" opacity=".85"/>`)}
    ${clock(470, 440, 62, '#FFF6EA', '#B8744E', '#5C3A2A')}
    ${plant(250, TABLE_Y + 150, '#C8765A', '#6F8F5E', '#86A56F', 0.8)}
    ${table('r', '#D19466', '#B5784D', '#E8B48A')}
    ${mug(1600, 790, '#FFF6EA', '#D9714B', '#5E3A26')}`,

  night: () => `
    <defs>
      ${grad('n-wall', [[0, '#232748'], [1, '#191C36']])}
      ${grad('n-sky', [[0, '#0E1331'], [1, '#2B3163']])}
      ${radial('n-lamp', [[0, '#FFD08A', 0.55], [0.5, '#FFC06A', 0.18], [1, '#FFC06A', 0]])}
    </defs>
    <rect width="${W}" height="${H}" fill="url(#n-wall)"/>
    ${window(1440, 116, 380, 420, '#2E3358', 'url(#n-sky)', `${Array.from({length: 22}, (_, i) => `<circle data-star="${i}" cx="${(i * 97) % 410 + 6}" cy="${(i * 53) % 200 + 10}" r="${i % 3 ? 1.6 : 2.4}" fill="#FFFFFF"/>`).join('')}<circle cx="310" cy="90" r="38" fill="#F6EED5"/><circle cx="326" cy="80" r="34" fill="#0F1433"/>${[[0, 250, 70, 170], [70, 290, 60, 130], [130, 230, 80, 190], [210, 300, 50, 120], [260, 260, 90, 160], [350, 310, 70, 110]].map(([x, y, w, h]) => `<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="#151A3A"/>${Array.from({length: 6}, (_, j) => `<rect data-city="${x + j}" x="${x + 10 + (j % 3) * 18}" y="${y + 16 + Math.floor(j / 3) * 26}" width="8" height="10" fill="#FFD27A" opacity="${(x + j) % 3 ? 0.85 : 0.25}"/>`).join('')}`).join('')}`)}

    ${table('n', '#2C3050', '#20233D', '#3C4170')}
    <circle data-lamp cx="300" cy="560" r="520" fill="url(#n-lamp)"/>
    <g transform="translate(300 800)"><ellipse cx="0" cy="0" rx="90" ry="14" fill="#000" opacity=".25"/><rect x="-60" y="-16" width="120" height="16" rx="6" fill="#3A3E60"/><rect x="-5" y="-230" width="10" height="220" fill="#4A4F78"/><path d="M-110 -210 l36 -120 h148 l36 120z" fill="#F0C98E"/><path d="M-110 -210 h220" stroke="#FFE7B8" stroke-width="4"/></g>
    ${mug(1640, 790, '#E8E3F4', '#8C7FC4', '#5A3A2A')}
    ${steam(1640, 650, '#C9C4E8')}
    <g transform="translate(1440 800) scale(.7)"><ellipse cx="0" cy="0" rx="150" ry="16" fill="#000" opacity=".2"/><rect x="-130" y="-34" width="260" height="30" rx="4" fill="#6F5A8E"/><rect x="-126" y="-38" width="252" height="8" rx="3" fill="#EFE8DA"/><rect x="-120" y="-64" width="240" height="28" rx="4" fill="#3E6C74"/><rect x="-116" y="-68" width="232" height="7" rx="3" fill="#EFE8DA"/></g>`,

  export: () => `
    <defs>
      ${grad('e-wall', [[0, '#3C3154'], [1, '#2C2441']])}
      ${grad('e-sky', [[0, '#5B4580'], [0.55, '#C98AA2'], [1, '#F2BF96']])}
    </defs>
    <rect width="${W}" height="${H}" fill="url(#e-wall)"/>
    ${window(1490, 116, 300, 420, '#4A3D66', 'url(#e-sky)', `<path d="M0 330 h50 v-40 l30 -30 l30 30 v40 h40 v-80 h60 v100 h50 v-50 h40 v70 h80 v120 h-380z" fill="#2B2140"/>`)}
    <path d="M0 70 q480 110 960 40 t960 30" fill="none" stroke="#6E5E88" stroke-width="3"/>
    ${Array.from({length: 18}, (_, i) => {
      const x = i * 112 + 40;
      const y = 70 + Math.sin(i * 0.9) * 22 + (i > 8 ? 12 : 30);
      return `<circle data-bulb="${i}" cx="${x}" cy="${y}" r="9" fill="#FFD68A"/>`;
    }).join('')}
    <g transform="translate(330 350) scale(.72)"><rect x="-120" y="0" width="240" height="280" rx="16" fill="#F5F0E8"/><path d="M-120 16 a16 16 0 0 1 16 -16 h208 a16 16 0 0 1 16 16 v56 h-240z" fill="#E0605A"/>
      <text x="0" y="52" text-anchor="middle" font-family="-apple-system, 'Helvetica Neue', sans-serif" font-size="36" font-weight="700" fill="#FFF" letter-spacing="6">FRI</text>
      <text x="0" y="200" text-anchor="middle" font-family="-apple-system, 'Helvetica Neue', sans-serif" font-size="128" font-weight="300" fill="#2B2438">25</text>
      <text x="0" y="248" text-anchor="middle" font-family="-apple-system, 'Helvetica Neue', sans-serif" font-size="26" font-weight="600" fill="#8B8198" letter-spacing="8">SEP</text></g>
    ${table('e', '#3E3554', '#2D2640', '#55497A')}
    ${plant(1620, TABLE_Y + 180, '#B98AA8', '#6E8F7A', '#86A88F', 0.72)}
    <g transform="translate(300 790)"><ellipse cx="0" cy="0" rx="70" ry="10" fill="#000" opacity=".2"/><path d="M-40 -150 h80 l-10 150 h-60z" fill="#E9E4F4" opacity=".35"/><path d="M-36 -80 h72 l-6 80 h-60z" fill="#E0A4B8" opacity=".75"/></g>`,
};

export const ROOM_IDS = Object.keys(ROOMS);

export function roomSVG(id) {
  return `<svg class="room" data-room="${id}" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" xmlns="http://www.w3.org/2000/svg">
    <defs><filter id="soft" x="-20%" y="-200%" width="140%" height="500%"><feGaussianBlur stdDeviation="14"/></filter></defs>
    ${ROOMS[id]()}
  </svg>`;
}
