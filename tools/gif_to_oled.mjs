#!/usr/bin/env node
/**
 * Convert any animated GIF into main/dancing_cat_frames.h (128x64 SSD1306 vertical page format)
 * using box-area downsampling, midtone gamma boost, and Atkinson 1-bit dithering.
 *
 * Usage:
 *   node tools/gif_to_oled.mjs "/storage/emulated/0/Download/Hololive Risu GIF.gif" main/dancing_cat_frames.h
 */

import fs from "fs";
import path from "path";
import { GifReader } from "omggif";

const gifPath = process.argv[2] || "/storage/emulated/0/Download/Hololive Risu GIF.gif";
const outHeader = process.argv[3] || "main/dancing_cat_frames.h";
const stretch = process.argv.includes("--stretch");

const buf = fs.readFileSync(gifPath);
const reader = new GifReader(buf);
const W = reader.width;
const H = reader.height;
const numFrames = reader.numFrames();

const OLED_W = 128;
const OLED_H = 64;
const scale = stretch ? 1 : Math.min(OLED_W / W, OLED_H / H);
const TARGET_W = stretch ? OLED_W : Math.max(1, Math.round(W * scale));
const TARGET_H = stretch ? OLED_H : Math.max(1, Math.round(H * scale));
const OFFSET_X = (OLED_W - TARGET_W) >> 1;
const OFFSET_Y = (OLED_H - TARGET_H) >> 1;

const rgbaCanvas = new Uint8Array(W * H * 4);
const prevCanvas = new Uint8Array(W * H * 4);
const packedFrames = [];

for (let f = 0; f < numFrames; f++) {
  const info = reader.frameInfo(f);
  if (info.disposal === 3) prevCanvas.set(rgbaCanvas);
  reader.decodeAndBlitFrameRGBA(f, rgbaCanvas);

  const gray = new Float32Array(OLED_W * OLED_H);
  const scaleX = W / TARGET_W;
  const scaleY = H / TARGET_H;

  for (let ty = 0; ty < TARGET_H; ty++) {
    const sy0 = Math.floor(ty * scaleY);
    const sy1 = Math.min(H, Math.ceil((ty + 1) * scaleY));
    for (let tx = 0; tx < TARGET_W; tx++) {
      const sx0 = Math.floor(tx * scaleX);
      const sx1 = Math.min(W, Math.ceil((tx + 1) * scaleX));
      let sum = 0;
      let count = 0;
      for (let sy = sy0; sy < sy1; sy++) {
        for (let sx = sx0; sx < sx1; sx++) {
          const idx = (sy * W + sx) * 4;
          const a = rgbaCanvas[idx + 3] / 255.0;
          const l = (0.299 * rgbaCanvas[idx] + 0.587 * rgbaCanvas[idx + 1] + 0.114 * rgbaCanvas[idx + 2]) * a;
          sum += l;
          count++;
        }
      }
      const norm = Math.pow(sum / (count * 255.0), 0.85) * 255.0;
      gray[(OFFSET_Y + ty) * OLED_W + (OFFSET_X + tx)] = norm;
    }
  }

  // Atkinson 1-bit dithering
  const bw = new Uint8Array(OLED_W * OLED_H);
  for (let y = OFFSET_Y; y < OFFSET_Y + TARGET_H; y++) {
    for (let x = OFFSET_X; x < OFFSET_X + TARGET_W; x++) {
      const i = y * OLED_W + x;
      const oldP = gray[i];
      const newP = oldP >= 118 ? 255 : 0;
      bw[i] = newP ? 1 : 0;
      const err = (oldP - newP) / 8.0;
      if (x + 1 < OLED_W) gray[i + 1] += err;
      if (x + 2 < OLED_W) gray[i + 2] += err;
      if (y + 1 < OLED_H) {
        if (x - 1 >= 0) gray[i + OLED_W - 1] += err;
        gray[i + OLED_W] += err;
        if (x + 1 < OLED_W) gray[i + OLED_W + 1] += err;
      }
      if (y + 2 < OLED_H) gray[i + 2 * OLED_W] += err;
    }
  }

  // Pack into SSD1306 page-addressed format (8 pages x 128 cols = 1024 bytes)
  const pageBuf = new Uint8Array(1024);
  for (let page = 0; page < 8; page++) {
    for (let x = 0; x < OLED_W; x++) {
      let b = 0;
      for (let bit = 0; bit < 8; bit++) {
        if (bw[(page * 8 + bit) * OLED_W + x]) b |= (1 << bit);
      }
      pageBuf[page * OLED_W + x] = b;
    }
  }
  packedFrames.push(pageBuf);

  if (info.disposal === 2) {
    for (let y = info.y; y < info.y + info.height; y++) {
      for (let x = info.x; x < info.x + info.width; x++) {
        const idx = (y * W + x) * 4;
        rgbaCanvas[idx] = rgbaCanvas[idx + 1] = rgbaCanvas[idx + 2] = rgbaCanvas[idx + 3] = 0;
      }
    }
  } else if (info.disposal === 3) {
    rgbaCanvas.set(prevCanvas);
  }
}

let out = `/* Auto-generated from ${path.basename(gifPath)} (${packedFrames.length} frames, 128x64 SSD1306 page format) */\n`;
out += "#ifndef DANCING_CAT_FRAMES_H\n#define DANCING_CAT_FRAMES_H\n\n";
out += "#include <stdint.h>\n#include <string.h>\n\n";
out += "#define OLED_WIDTH              128\n";
out += "#define OLED_HEIGHT             64\n";
out += "#define OLED_PAGES              (OLED_HEIGHT / 8)\n";
out += "#define OLED_FRAME_BYTES        (OLED_WIDTH * OLED_PAGES)\n";
out += `#define DANCING_CAT_NUM_FRAMES  ${packedFrames.length}\n\n`;
out += "static const uint8_t s_dancing_cat_gif_bitmap[DANCING_CAT_NUM_FRAMES][OLED_FRAME_BYTES] = {\n";

for (let f = 0; f < packedFrames.length; f++) {
  out += `    /* Frame ${f} */\n    {\n        `;
  const frame = packedFrames[f];
  const hex = Array.from(frame, (b) => "0x" + b.toString(16).toUpperCase().padStart(2, "0"));
  for (let i = 0; i < hex.length; i += 16) {
    out += hex.slice(i, i + 16).join(", ");
    out += i + 16 < hex.length ? ",\n        " : "\n";
  }
  out += "    },\n";
}
out += "};\n\n";
out += "static inline void dancing_cat_render_frame(uint8_t *buf, int frame_idx)\n{\n";
out += "    int idx = frame_idx % DANCING_CAT_NUM_FRAMES;\n";
out += "    memcpy(buf, s_dancing_cat_gif_bitmap[idx], OLED_FRAME_BYTES);\n}\n\n";
out += "#endif /* DANCING_CAT_FRAMES_H */\n";

fs.writeFileSync(outHeader, out);
console.log(`Converted ${packedFrames.length} frames (${packedFrames.length * 1024} bytes) -> ${outHeader}`);
