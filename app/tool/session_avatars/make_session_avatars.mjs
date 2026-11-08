// Generates the session-list avatar gallery (app/assets/session_avatars/):
// DiceBear "Critters" avatars, one transparent 96 px PNG per gallery slot,
// deterministic per seed so re-running with the pinned dependencies (see
// package.json) reproduces the same images byte for byte.
//
// The app picks a slot by FNV-1a of the session id (DshColors.identityIndex,
// SessionAvatarGallery.count), so every conversation keeps its avatar across
// restarts, reinstalls and hosts without any runtime dependency on DiceBear.
//
// Setup once (npm needs network):
//   cd tool/session_avatars && npm install --registry=https://registry.npmmirror.com
// Run from app/:
//   node tool/session_avatars/make_session_avatars.mjs [--preview out.png]
//
// Art: the "Critters" style from DiceBear 10 (https://www.dicebear.com/styles/critters/),
// dedicated to the public domain under CC0 1.0 — no attribution required.
// Provenance is documented in THIRD_PARTY_NOTICES.md (素材 section).

import { Avatar, Style } from '@dicebear/core';
import critters from '@dicebear/styles/critters.json' with { type: 'json' };
import { Resvg } from '@resvg/resvg-js';
import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
// .../app/assets/session_avatars
const outDir = join(here, '..', '..', 'assets', 'session_avatars');

const count = 100;
const pixels = 96; // 32 dp at 3x; Flutter downsamples for lower densities.
const seedPrefix = 'dsh';

const previewIndex = process.argv.indexOf('--preview');
const preview = previewIndex > 0 ? process.argv[previewIndex + 1] : null;

await mkdir(outDir, { recursive: true });
const cells = [];
for (let i = 0; i < count; i++) {
  const svg = new Avatar(new Style(critters), { seed: `${seedPrefix}-${i}` }).toString();
  const png = new Resvg(svg, { fitTo: { mode: 'width', value: pixels } }).render().asPng();
  const name = `avatar_${String(i).padStart(2, '0')}.png`;
  await writeFile(join(outDir, name), png);
  cells.push(png);
  process.stdout.write(`\r${i + 1}/${count}`);
}
process.stdout.write('\n');

if (preview != null) {
  const columns = 10;
  const size = 96;
  const gap = 8;
  const rows = Math.ceil(count / columns);
  const cell = (png, x, y, tint) =>
    `<g transform="translate(${x},${y})"><circle cx="${size / 2}" cy="${size / 2}" r="${size / 2}" fill="${tint}"/>` +
    `<image width="${size}" height="${size}" href="data:image/png;base64,${png.toString('base64')}"/></g>`;
  // The app's light-theme identity palette (semantic_colors.dart).
  const tints = ['#DAECFF', '#E9E6FF', '#F9E1F3', '#FFE2E0', '#F8E6D1', '#E0EFD8', '#D3F1E9', '#D1F0F8'];
  const margin = 16;
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" width="${margin * 2 + columns * (size + gap)}" ` +
    `height="${margin * 2 + rows * (size + gap)}"><rect width="100%" height="100%" fill="#ffffff"/>` +
    cells
      .map((png, i) =>
        cell(png, margin + (i % columns) * (size + gap), margin + Math.floor(i / columns) * (size + gap), tints[i % tints.length]),
      )
      .join('') +
    `</svg>`;
  await writeFile(preview, new Resvg(svg).render().asPng());
  console.log(`preview: ${preview}`);
}
console.log(`${count} avatars in ${outDir}`);
