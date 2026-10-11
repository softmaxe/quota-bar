/* Local color palettes. This file does not change layout or chart behavior. */
(function (root) {
  'use strict';
  const palettes = {
  "editorial": {
    "NAME": "editorial",
    "PAGE": "#111313",
    "SURFACE": "#1B1D1D",
    "SURFACE_LIFT": "#252727",
    "ON_HI": "#171919",
    "INK": "#EEEEEA",
    "LAB": "#C7C9C6",
    "MUT": "#ADB0AC",
    "LINE": "#90938F",
    "GRID": "#424644",
    "QUIET": "#303431",
    "HERO": "#EEEEEA",
    "RAMP": [
      "#858783",
      "#9DA09A",
      "#B9BCB5",
      "#D3D6CE",
      "#EEEEEA"
    ],
    "CAT": [
      "#EEEEEA",
      "#D0D3CC",
      "#B5B9B0",
      "#9CA196",
      "#899082",
      "#C2C6BC"
    ]
  },
  "palm": {
    "NAME": "palm",
    "PAGE": "#101513",
    "SURFACE": "#171D19",
    "SURFACE_LIFT": "#222A23",
    "ON_HI": "#171D19",
    "INK": "#F0F0E6",
    "LAB": "#C7CFB9",
    "MUT": "#ABB79D",
    "LINE": "#88966F",
    "GRID": "#3D4936",
    "QUIET": "#2B382B",
    "HERO": "#F2D17E",
    "RAMP": [
      "#84936C",
      "#9CA778",
      "#B6BE8A",
      "#D0D19F",
      "#F2D17E"
    ],
    "CAT": [
      "#C8CAA8",
      "#92A77B",
      "#F2D17E",
      "#AEB988",
      "#DAD8B3",
      "#B5C8A2"
    ]
  }
};
  for (const theme of Object.values(palettes)) {
    Object.freeze(theme.RAMP);
    Object.freeze(theme.CAT);
    Object.freeze(theme);
  }
  Object.freeze(palettes);
  const palette = name => {
    if (!Object.hasOwn(palettes, name)) throw new Error('Unknown palette: ' + name);
    return palettes[name];
  };
  const alpha = (hex, opacity) => {
    const channels = [1, 3, 5].map(index => parseInt(hex.slice(index, index + 2), 16));
    return 'rgba(' + channels.join(',') + ',' + opacity + ')';
  };
  const install = theme => {
    const doc = root.document;
    const style = doc.getElementById('chart-colors') || doc.createElement('style');
    style.id = 'chart-colors';
    const variables = Object.entries(theme).flatMap(([role, value]) => {
      if (role === 'NAME') return [];
      const key = '--chart-' + role.toLowerCase().replaceAll('_', '-');
      return Array.isArray(value) ? value.map((color, index) => key + '-' + index + ':' + color) : [key + ':' + value];
    });
    style.textContent = ':root{color-scheme:dark;' + variables.join(';') + '}';
    if (!style.isConnected) doc.head.appendChild(style);
  };
  root.CHART = Object.freeze({ palettes, palette, install, alpha });
})(globalThis);
