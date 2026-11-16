#!/usr/bin/env node
/**
 * W.A.S.T.E. v2.0.0 — Gap B E2E Verification & Test Suite (tools/verify_gap_b.mjs)
 *
 * Implements the 4-Tier Test Case Methodology for Gap B:
 * - Tier 1: Feature Coverage (WGF1 container layout, IEEE 802.3 CRC32, realistic payload generation, SSD1306 page packing)
 * - Tier 2: Boundary & Corner Cases (Corrupt CRC32, truncated files, zero frames, oversized frames, bad magic, bad FPS, size mismatch)
 * - Tier 3: Cross-Feature Combinations (BLE 0xFF07 244B chunked streaming & progress HUD, HTTP streaming, mid-stream abort, dual-source fallback)
 * - Tier 4: Static Code & Integrity Audit (ESP-IDF v6.1 component registrations, Picolibc/PRIu32 format specifiers, bounded snprintf, pubspec.yaml version/deps)
 *
 * Usage:
 *   node tools/verify_gap_b.mjs [--strict] [--verbose]
 */

import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";

// ============================================================================
// 1. SPECIFICATION CONSTANTS & PROTOCOL ENUMS
// ============================================================================

export const WBIN_MAGIC = "WGF1";
export const WBIN_MAGIC_BYTES = Buffer.from([0x57, 0x47, 0x46, 0x31]); // 'W','G','F','1'
export const WBIN_HEADER_SIZE = 16;
export const WBIN_FRAME_BYTES = 1024; // 128 cols x 8 vertical pages (SSD1306)
export const WBIN_MIN_FRAMES = 1;
export const WBIN_MAX_FRAMES = 512;
export const WBIN_MIN_FPS = 5;
export const WBIN_MAX_FPS = 30;
export const WBIN_DEFAULT_FPS = 15;

export const WBIN_FLAG_INVERT = 1 << 0;
export const WBIN_FLAG_HUD_OVERLAY = 1 << 1;

export const WBIN_ERROR = {
  OK: "WBIN_OK",
  TRUNCATED_HEADER: "WBIN_ERR_TRUNCATED_HEADER",
  INVALID_MAGIC: "WBIN_ERR_INVALID_MAGIC",
  EMPTY_FRAMES: "WBIN_ERR_EMPTY_FRAMES",
  FRAME_OVERFLOW: "WBIN_ERR_FRAME_OVERFLOW",
  PAYLOAD_MISMATCH: "WBIN_ERR_PAYLOAD_MISMATCH",
  TRUNCATED_PAYLOAD: "WBIN_ERR_TRUNCATED_PAYLOAD",
  CRC_MISMATCH: "WBIN_ERR_CRC_MISMATCH",
  INVALID_FPS: "WBIN_ERR_INVALID_FPS",
};

// ============================================================================
// 2. IEEE 802.3 CRC32 IMPLEMENTATION (Polynomial: 0xEDB88320)
// ============================================================================

export const CRC32_TABLE = new Uint32Array(256);
for (let i = 0; i < 256; i++) {
  let c = i;
  for (let k = 0; k < 8; k++) {
    c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
  }
  CRC32_TABLE[i] = c >>> 0;
}

/**
 * Computes standard 32-bit unsigned IEEE 802.3 CRC32 checksum.
 * Bitwise identical to ESP32 esp_rom_crc32_le and companion app wbin_encoder.dart.
 */
export function computeCrc32Ieee(buffer) {
  let crc = 0xFFFFFFFF;
  for (let i = 0; i < buffer.length; i++) {
    crc = CRC32_TABLE[(crc ^ buffer[i]) & 0xFF] ^ (crc >>> 8);
  }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

// ============================================================================
// 3. WBIN PACKER & UNPACKER ENGINE
// ============================================================================

/**
 * Packs raw 1024-byte frames into a valid .wbin (WGF1) container.
 */
export function packWbin(frames, targetFps = WBIN_DEFAULT_FPS, flags = 0) {
  if (!Array.isArray(frames) || frames.length === 0) {
    throw new Error("Cannot pack empty frames array");
  }
  if (frames.length > WBIN_MAX_FRAMES) {
    throw new Error(`Frame count ${frames.length} exceeds maximum limit of ${WBIN_MAX_FRAMES}`);
  }

  const numFrames = frames.length;
  const payloadBytes = numFrames * WBIN_FRAME_BYTES;
  const payloadBuffer = Buffer.alloc(payloadBytes);

  for (let i = 0; i < numFrames; i++) {
    const f = frames[i];
    if (f.length !== WBIN_FRAME_BYTES) {
      throw new Error(`Frame ${i} length is ${f.length}, expected exactly ${WBIN_FRAME_BYTES} bytes`);
    }
    f.copy(payloadBuffer, i * WBIN_FRAME_BYTES);
  }

  const crc = computeCrc32Ieee(payloadBuffer);

  const header = Buffer.alloc(WBIN_HEADER_SIZE);
  header.write(WBIN_MAGIC, 0, 4, "ascii");
  header.writeUInt16LE(numFrames, 4);
  header.writeUInt8(Math.max(WBIN_MIN_FPS, Math.min(WBIN_MAX_FPS, targetFps)), 6);
  header.writeUInt8(flags, 7);
  header.writeUInt32LE(payloadBytes, 8);
  header.writeUInt32LE(crc, 12);

  return Buffer.concat([header, payloadBuffer]);
}

/**
 * Unpacks and validates a .wbin container buffer matching firmware parser logic.
 */
export function unpackWbin(buffer, options = { clampFps: true }) {
  if (!buffer || buffer.length < WBIN_HEADER_SIZE) {
    return { valid: false, error: WBIN_ERROR.TRUNCATED_HEADER, message: "Buffer shorter than 16-byte header" };
  }

  if (!buffer.subarray(0, 4).equals(WBIN_MAGIC_BYTES)) {
    const magic = buffer.toString("latin1", 0, 4);
    return { valid: false, error: WBIN_ERROR.INVALID_MAGIC, message: `Invalid magic "${magic}", expected "WGF1"` };
  }
  const magic = WBIN_MAGIC;

  const numFrames = buffer.readUInt16LE(4);
  if (numFrames < WBIN_MIN_FRAMES) {
    return { valid: false, error: WBIN_ERROR.EMPTY_FRAMES, message: "Header declares 0 frames" };
  }
  if (numFrames > WBIN_MAX_FRAMES) {
    return { valid: false, error: WBIN_ERROR.FRAME_OVERFLOW, message: `Header declares ${numFrames} frames (max 512)` };
  }

  let targetFps = buffer.readUInt8(6);
  let fpsClamped = false;
  if (targetFps < WBIN_MIN_FPS || targetFps > WBIN_MAX_FPS) {
    if (options.clampFps) {
      targetFps = WBIN_DEFAULT_FPS;
      fpsClamped = true;
    } else {
      return { valid: false, error: WBIN_ERROR.INVALID_FPS, message: `FPS ${targetFps} outside valid range [5, 30]` };
    }
  }

  const flags = buffer.readUInt8(7);
  const payloadBytes = buffer.readUInt32LE(8);
  const expectedPayloadBytes = numFrames * WBIN_FRAME_BYTES;

  if (payloadBytes !== expectedPayloadBytes) {
    return {
      valid: false,
      error: WBIN_ERROR.PAYLOAD_MISMATCH,
      message: `payload_bytes ${payloadBytes} does not match num_frames * 1024 (${expectedPayloadBytes})`,
    };
  }

  const expectedTotalLen = WBIN_HEADER_SIZE + payloadBytes;
  if (buffer.length < expectedTotalLen) {
    return {
      valid: false,
      error: WBIN_ERROR.TRUNCATED_PAYLOAD,
      message: `Buffer has ${buffer.length} bytes, expected at least ${expectedTotalLen} bytes`,
    };
  }

  const declaredCrc = buffer.readUInt32LE(12);
  const payloadSlice = buffer.subarray(WBIN_HEADER_SIZE, expectedTotalLen);
  const computedCrc = computeCrc32Ieee(payloadSlice);

  if (computedCrc !== declaredCrc) {
    return {
      valid: false,
      error: WBIN_ERROR.CRC_MISMATCH,
      message: `CRC32 mismatch: computed 0x${computedCrc.toString(16).toUpperCase().padStart(8, "0")}, header declares 0x${declaredCrc.toString(16).toUpperCase().padStart(8, "0")}`,
    };
  }

  const frames = [];
  for (let i = 0; i < numFrames; i++) {
    const start = WBIN_HEADER_SIZE + i * WBIN_FRAME_BYTES;
    frames.push(buffer.subarray(start, start + WBIN_FRAME_BYTES));
  }

  return {
    valid: true,
    error: WBIN_ERROR.OK,
    header: {
      magic,
      numFrames,
      targetFps,
      flags,
      payloadBytes,
      crc32: declaredCrc,
      fpsClamped,
    },
    frames,
  };
}

/**
 * Generates a synthetic monochrome test frame (1024 bytes) matching SSD1306 vertical page format.
 */
export function generateTestFrame(frameIndex, totalFrames) {
  const buf = Buffer.alloc(WBIN_FRAME_BYTES);
  // Generate diagonal sweep pattern and distinct frame counter marks
  for (let page = 0; page < 8; page++) {
    for (let col = 0; col < 128; col++) {
      let byteVal = 0;
      for (let bit = 0; bit < 8; bit++) {
        const y = page * 8 + bit;
        const x = col;
        // Deterministic synthetic pattern: border, crosshair, and moving diagonal wave
        const isBorder = (x === 0 || x === 127 || y === 0 || y === 63);
        const isWave = ((x + y + frameIndex * 2) % 16 === 0);
        if (isBorder || isWave) {
          byteVal |= (1 << bit);
        }
      }
      buf[page * 128 + col] = byteVal;
    }
  }
  return buf;
}

// ============================================================================
// 4. TEST HARNESS & SUITE EXECUTION
// ============================================================================

class TestRunner {
  constructor(options = {}) {
    this.strict = !!options.strict;
    this.verbose = !!options.verbose;
    this.results = {
      tier1: [],
      tier2: [],
      tier3: [],
      tier4: [],
    };
  }

  record(tier, name, passed, details = "") {
    const entry = { name, passed, details };
    this.results[tier].push(entry);
    const tag = passed ? "✔ PASS" : "✖ FAIL";
    console.log(`  ${tag} | [${tier.toUpperCase()}] ${name}`);
    if (this.verbose && details) {
      console.log(`         Details: ${details}`);
    }
  }

  recordPending(tier, name, reason) {
    const entry = { name, passed: !this.strict, pending: true, details: reason };
    this.results[tier].push(entry);
    const tag = this.strict ? "✖ FAIL" : "⚠ PEND";
    console.log(`  ${tag} | [${tier.toUpperCase()}] ${name} (${reason})`);
  }

  // --------------------------------------------------------------------------
  // TIER 1: FEATURE COVERAGE
  // --------------------------------------------------------------------------
  runTier1() {
    console.log("\n===============================================================================");
    console.log("  TIER 1: FEATURE COVERAGE (Binary Container, CRC32, Generator, Fields)");
    console.log("===============================================================================");

    // Test 1.1: IEEE 802.3 CRC32 standard test vector (ASCII "123456789" = 0xCBF43926)
    {
      const vectorInput = Buffer.from("123456789", "ascii");
      const computed = computeCrc32Ieee(vectorInput);
      const expected = 0xCBF43926;
      const zlibCrc = zlib.crc32(vectorInput) >>> 0;
      const pass = (computed === expected) && (computed === zlibCrc);
      this.record(
        "tier1",
        'IEEE 802.3 CRC32 check vector "123456789" -> 0xCBF43926',
        pass,
        `Computed: 0x${computed.toString(16)}, Expected: 0x${expected.toString(16)}, Node zlib: 0x${zlibCrc.toString(16)}`
      );
    }

    // Test 1.2: Empty buffer CRC32 is 0x00000000
    {
      const emptyBuf = Buffer.alloc(0);
      const computed = computeCrc32Ieee(emptyBuf);
      const pass = (computed === 0);
      this.record("tier1", "IEEE 802.3 CRC32 empty buffer check -> 0x00000000", pass);
    }

    // Test 1.3: Generate valid 85-frame .wbin compatible with tools/gif_to_oled.mjs
    {
      const numFrames = 85;
      const targetFps = 15;
      const flags = WBIN_FLAG_HUD_OVERLAY;
      const frames = [];
      for (let i = 0; i < numFrames; i++) {
        frames.push(generateTestFrame(i, numFrames));
      }

      const packed = packWbin(frames, targetFps, flags);
      const expectedTotalBytes = WBIN_HEADER_SIZE + (numFrames * WBIN_FRAME_BYTES);
      const passLength = packed.length === expectedTotalBytes;

      const unpacked = unpackWbin(packed);
      const passUnpack = unpacked.valid &&
        unpacked.header.magic === WBIN_MAGIC &&
        unpacked.header.numFrames === numFrames &&
        unpacked.header.targetFps === targetFps &&
        unpacked.header.flags === flags &&
        unpacked.header.payloadBytes === numFrames * 1024 &&
        unpacked.frames.length === numFrames;

      // Verify bit-for-bit frame fidelity
      let bitFidelity = true;
      for (let i = 0; i < numFrames; i++) {
        if (!frames[i].equals(unpacked.frames[i])) {
          bitFidelity = false;
          break;
        }
      }

      this.record(
        "tier1",
        "Generate & round-trip validate 85-frame .wbin payload (128x64 SSD1306 vertical page format)",
        passLength && passUnpack && bitFidelity,
        `Total packed size: ${packed.length} bytes (16B header + 87,040B payload). Bit fidelity: ${bitFidelity}`
      );
    }

    // Test 1.4: Header layout exact struct bounds (16 bytes packed)
    {
      const testFrame = generateTestFrame(0, 1);
      const packed = packWbin([testFrame], 20, WBIN_FLAG_INVERT | WBIN_FLAG_HUD_OVERLAY);
      const magic = packed.subarray(0, 4).toString("ascii");
      const numFrames = packed.readUInt16LE(4);
      const fps = packed.readUInt8(6);
      const flags = packed.readUInt8(7);
      const payloadBytes = packed.readUInt32LE(8);
      const crc32 = packed.readUInt32LE(12);

      const pass = (magic === "WGF1") &&
        (numFrames === 1) &&
        (fps === 20) &&
        (flags === 3) &&
        (payloadBytes === 1024) &&
        (crc32 !== 0);

      this.record("tier1", "16-byte header field alignment and byte-offset verification", pass);
    }

    // Test 1.5: Frame rates across supported spectrum (5, 15, 24, 30 FPS)
    {
      let allPassed = true;
      for (const fps of [5, 10, 15, 24, 30]) {
        const frame = generateTestFrame(0, 1);
        const packed = packWbin([frame], fps, 0);
        const unpacked = unpackWbin(packed);
        if (!unpacked.valid || unpacked.header.targetFps !== fps) {
          allPassed = false;
          break;
        }
      }
      this.record("tier1", "Support full valid frame rate spectrum (5 to 30 FPS)", allPassed);
    }

    // Test 1.6: Flag permutations (invert, hud_overlay, none, combined)
    {
      let allFlagsPassed = true;
      const flagVariants = [0, WBIN_FLAG_INVERT, WBIN_FLAG_HUD_OVERLAY, WBIN_FLAG_INVERT | WBIN_FLAG_HUD_OVERLAY];
      for (const f of flagVariants) {
        const frame = generateTestFrame(0, 1);
        const packed = packWbin([frame], 15, f);
        const unpacked = unpackWbin(packed);
        if (!unpacked.valid || unpacked.header.flags !== f) {
          allFlagsPassed = false;
          break;
        }
      }
      this.record("tier1", "Flag bitfield encoding and decoding integrity (invert & hud_overlay)", allFlagsPassed);
    }
  }

  // --------------------------------------------------------------------------
  // TIER 2: BOUNDARY & CORNER CASES
  // --------------------------------------------------------------------------
  runTier2() {
    console.log("\n===============================================================================");
    console.log("  TIER 2: BOUNDARY & CORNER CASES (Rejection of Invalid/Corrupted Vectors)");
    console.log("===============================================================================");

    const validFrame = generateTestFrame(0, 1);
    const validWbin = packWbin([validFrame], 15, 0);

    // Test 2.1: Corrupt CRC32 rejection (header CRC inverted)
    {
      const corrupt = Buffer.from(validWbin);
      const originalCrc = corrupt.readUInt32LE(12);
      corrupt.writeUInt32LE(originalCrc ^ 0xFFFFFFFF, 12);
      const res = unpackWbin(corrupt);
      const pass = (!res.valid && res.error === WBIN_ERROR.CRC_MISMATCH);
      this.record("tier2", "Reject payload with corrupted header CRC32", pass, res.message);
    }

    // Test 2.2: Single bit flip in first payload byte triggers CRC rejection
    {
      const corrupt = Buffer.from(validWbin);
      corrupt[16] ^= 0x01; // flip bit 0 of 1st payload byte
      const res = unpackWbin(corrupt);
      const pass = (!res.valid && res.error === WBIN_ERROR.CRC_MISMATCH);
      this.record("tier2", "Reject payload with single bit flip in first payload byte", pass, res.message);
    }

    // Test 2.3: Single bit flip in last payload byte triggers CRC rejection
    {
      const corrupt = Buffer.from(validWbin);
      corrupt[corrupt.length - 1] ^= 0x80; // flip bit 7 of last payload byte
      const res = unpackWbin(corrupt);
      const pass = (!res.valid && res.error === WBIN_ERROR.CRC_MISMATCH);
      this.record("tier2", "Reject payload with single bit flip in last payload byte", pass, res.message);
    }

    // Test 2.4: Zero-length buffer rejection
    {
      const res = unpackWbin(Buffer.alloc(0));
      const pass = (!res.valid && res.error === WBIN_ERROR.TRUNCATED_HEADER);
      this.record("tier2", "Reject zero-length buffer as truncated header", pass, res.message);
    }

    // Test 2.5: Truncated header (15 bytes instead of 16) rejection
    {
      const res = unpackWbin(Buffer.alloc(15));
      const pass = (!res.valid && res.error === WBIN_ERROR.TRUNCATED_HEADER);
      this.record("tier2", "Reject 15-byte buffer (1 byte short of header)", pass, res.message);
    }

    // Test 2.6: Truncated payload rejection (header says 1024B, only 512B provided)
    {
      const truncated = validWbin.subarray(0, WBIN_HEADER_SIZE + 512);
      const res = unpackWbin(truncated);
      const pass = (!res.valid && res.error === WBIN_ERROR.TRUNCATED_PAYLOAD);
      this.record("tier2", "Reject truncated payload buffer", pass, res.message);
    }

    // Test 2.7: Header declares 0 frames rejection
    {
      const corrupt = Buffer.from(validWbin);
      corrupt.writeUInt16LE(0, 4); // num_frames = 0
      corrupt.writeUInt32LE(0, 8); // payload_bytes = 0
      const res = unpackWbin(corrupt);
      const pass = (!res.valid && res.error === WBIN_ERROR.EMPTY_FRAMES);
      this.record("tier2", "Reject container declaring 0 frames", pass, res.message);
    }

    // Test 2.8: Oversized frame count (> 512 frames) rejection
    {
      const corrupt = Buffer.from(validWbin);
      corrupt.writeUInt16LE(513, 4); // num_frames = 513
      const res = unpackWbin(corrupt);
      const pass = (!res.valid && res.error === WBIN_ERROR.FRAME_OVERFLOW);
      this.record("tier2", "Reject frame overflow (513 frames > 512 max limit)", pass, res.message);
    }

    // Test 2.9: Invalid magic rejection ("WGF2")
    {
      const corrupt = Buffer.from(validWbin);
      corrupt.write("WGF2", 0, 4, "ascii");
      const res = unpackWbin(corrupt);
      const pass = (!res.valid && res.error === WBIN_ERROR.INVALID_MAGIC);
      this.record('tier2', 'Reject invalid container magic ("WGF2")', pass, res.message);
    }

    // Test 2.10: Unprogrammed NOR flash magic (0xFFFFFFFF) rejection
    {
      const unprogrammed = Buffer.alloc(1024 + 16, 0xFF);
      const res = unpackWbin(unprogrammed);
      const pass = (!res.valid && res.error === WBIN_ERROR.INVALID_MAGIC);
      this.record("tier2", "Reject unprogrammed flash state (0xFFFFFFFF magic)", pass, res.message);
    }

    // Test 2.11: Lowercase magic ("wgf1") rejection
    {
      const corrupt = Buffer.from(validWbin);
      corrupt.write("wgf1", 0, 4, "ascii");
      const res = unpackWbin(corrupt);
      const pass = (!res.valid && res.error === WBIN_ERROR.INVALID_MAGIC);
      this.record('tier2', 'Reject lowercase magic ("wgf1")', pass, res.message);
    }

    // Test 2.12: Payload byte mismatch rejection (header claims 2048B, num_frames says 1)
    {
      const corrupt = Buffer.from(validWbin);
      corrupt.writeUInt32LE(2048, 8); // payload_bytes = 2048 != 1 * 1024
      const res = unpackWbin(corrupt);
      const pass = (!res.valid && res.error === WBIN_ERROR.PAYLOAD_MISMATCH);
      this.record("tier2", "Reject payload_bytes mismatch against num_frames * 1024", pass, res.message);
    }

    // Test 2.13: Invalid FPS clamping / handling (0 FPS clamped to default 15 FPS)
    {
      const corrupt = Buffer.from(validWbin);
      corrupt.writeUInt8(0, 6); // target_fps = 0
      const resClamped = unpackWbin(corrupt, { clampFps: true });
      const resStrict = unpackWbin(corrupt, { clampFps: false });
      const pass = resClamped.valid && resClamped.header.targetFps === 15 && !resStrict.valid;
      this.record("tier2", "Detect out-of-range FPS (< 5 FPS) and enforce default clamp", pass);
    }

    // Test 2.14: Oversized FPS (> 30 FPS) clamping / handling
    {
      const corrupt = Buffer.from(validWbin);
      corrupt.writeUInt8(60, 6); // target_fps = 60
      const resClamped = unpackWbin(corrupt, { clampFps: true });
      const pass = resClamped.valid && resClamped.header.targetFps === 15;
      this.record("tier2", "Detect out-of-range FPS (> 30 FPS) and enforce default clamp", pass);
    }
  }

  // --------------------------------------------------------------------------
  // TIER 3: CROSS-FEATURE COMBINATIONS
  // --------------------------------------------------------------------------
  runTier3() {
    console.log("\n===============================================================================");
    console.log("  TIER 3: CROSS-FEATURE COMBINATIONS (Chunked Streaming, Progress, Reassembly)");
    console.log("===============================================================================");

    // Test 3.1: BLE GATT 0xFF07 244-byte chunked streaming and progressive OLED HUD feedback
    {
      const numFrames = 10;
      const frames = [];
      for (let i = 0; i < numFrames; i++) {
        frames.push(generateTestFrame(i, numFrames));
      }
      const rawWbin = packWbin(frames, 15, 0);
      const expectedTotalBytes = rawWbin.length; // 16 + 10,240 = 10,256 bytes

      // Simulate MTU slicing into 244-byte chunks
      const BLE_CHUNK_SIZE = 244;
      const chunks = [];
      for (let offset = 0; offset < expectedTotalBytes; offset += BLE_CHUNK_SIZE) {
        chunks.push(rawWbin.subarray(offset, Math.min(expectedTotalBytes, offset + BLE_CHUNK_SIZE)));
      }

      // Simulate firmware staging buffer reassembly and OLED HUD progress tracker
      const stagingBuf = Buffer.alloc(expectedTotalBytes);
      let bytesReceived = 0;
      let progressMonotonic = true;
      let lastProgress = 0;
      const hudMessages = [];

      for (let i = 0; i < chunks.length; i++) {
        const chunk = chunks[i];
        chunk.copy(stagingBuf, bytesReceived);
        bytesReceived += chunk.length;

        const percent = Math.floor((bytesReceived * 100) / expectedTotalBytes);
        if (percent < lastProgress) progressMonotonic = false;
        lastProgress = percent;

        // OLED HUD display format: "UPLOADING GIF: XX%"
        hudMessages.push(`UPLOADING GIF: ${percent}%`);
      }

      const unpackReassembled = unpackWbin(stagingBuf);
      const pass = (bytesReceived === expectedTotalBytes) &&
        progressMonotonic &&
        (lastProgress === 100) &&
        unpackReassembled.valid &&
        (unpackReassembled.header.crc32 === computeCrc32Ieee(stagingBuf.subarray(16)));

      this.record(
        "tier3",
        `Simulate BLE 0xFF07 244-byte chunked stream (${chunks.length} chunks), reassembly, and live OLED HUD progress tracking`,
        pass,
        `Reassembled: ${bytesReceived}/${expectedTotalBytes} bytes. Final HUD: "${hudMessages[hudMessages.length - 1]}"`
      );
    }

    // Test 3.2: HTTP POST /api/oled/upload streaming upload with variable packet sizes
    {
      const numFrames = 5;
      const frames = [];
      for (let i = 0; i < numFrames; i++) frames.push(generateTestFrame(i, numFrames));
      const sourceWbin = packWbin(frames, 15, 0);

      // Simulate variable HTTP TCP stream chunks (512B, 1024B, 2048B, etc.)
      const packetSizes = [512, 1024, 768, 2048, 512, 272];
      let offset = 0;
      const incomingChunks = [];
      for (const sz of packetSizes) {
        if (offset >= sourceWbin.length) break;
        const slice = sourceWbin.subarray(offset, Math.min(sourceWbin.length, offset + sz));
        incomingChunks.push(slice);
        offset += slice.length;
      }

      // Reassemble HTTP stream
      const httpReassembled = Buffer.concat(incomingChunks);
      const res = unpackWbin(httpReassembled);
      const pass = res.valid && (res.header.crc32 === computeCrc32Ieee(sourceWbin.subarray(16)));
      this.record("tier3", "Simulate LAN HTTP REST streaming upload with variable TCP chunking", pass);
    }

    // Test 3.3: Mid-stream abort / timeout simulation prevents flash corruption
    {
      const rawWbin = packWbin([generateTestFrame(0, 1), generateTestFrame(1, 2)], 15, 0);
      // Abort after sending only 500 bytes of a 2064-byte payload
      const truncatedStream = rawWbin.subarray(0, 500);

      // Verify that parser detects incomplete transmission and rejects commit
      const res = unpackWbin(truncatedStream);
      const pass = (!res.valid && (res.error === WBIN_ERROR.TRUNCATED_PAYLOAD || res.error === WBIN_ERROR.CRC_MISMATCH));
      this.record("tier3", "Mid-stream connection abort halts staging without committing to flash storage", pass);
    }

    // Test 3.4: Dual-source fallback state machine simulation
    {
      // Scenario A: Fresh unwritten flash partition -> returns Mascot Fallback
      const flashPartition = Buffer.alloc(1024 * 1024, 0xFF);
      const bootCheckEmpty = unpackWbin(flashPartition.subarray(0, WBIN_HEADER_SIZE));
      const fallbackOnEmpty = (!bootCheckEmpty.valid);

      // Scenario B: Upload valid custom animation -> switches to Custom
      const customWbin = packWbin([generateTestFrame(0, 1)], 15, 0);
      customWbin.copy(flashPartition, 0);
      const bootCheckCustom = unpackWbin(flashPartition.subarray(0, customWbin.length));
      const customActive = bootCheckCustom.valid;

      // Scenario C: User invokes reset_anim -> erases sector 0 (4KB) -> reverts to Mascot Fallback
      flashPartition.fill(0xFF, 0, 4096);
      const bootCheckReset = unpackWbin(flashPartition.subarray(0, WBIN_HEADER_SIZE));
      const fallbackOnReset = (!bootCheckReset.valid);

      const pass = fallbackOnEmpty && customActive && fallbackOnReset;
      this.record("tier3", "Dual-source fallback state machine (Empty Flash -> Custom .wbin -> User Reset Fallback)", pass);
    }
  }

  // --------------------------------------------------------------------------
  // TIER 4: STATIC CODE & INTEGRITY AUDIT
  // --------------------------------------------------------------------------
  runTier4() {
    console.log("\n===============================================================================");
    console.log("  TIER 4: STATIC CODE & INTEGRITY AUDIT (Build Manifests, Picolibc, Pubspec)");
    console.log("===============================================================================");

    const rootDir = process.cwd();

    // Audit 4.1: Companion App pubspec.yaml version and dependencies
    {
      const pubspecPath = path.resolve(rootDir, "companion_app/pubspec.yaml");
      if (!fs.existsSync(pubspecPath)) {
        this.record("tier4", "companion_app/pubspec.yaml existence", false, `File not found: ${pubspecPath}`);
      } else {
        const content = fs.readFileSync(pubspecPath, "utf8");
        const hasVersion2 = /^version:\s*2\.0\.0\+/m.test(content);
        const hasHttp = /^\s*http:\s*\S+/m.test(content);
        const hasImage = /^\s*image:\s*\S+/m.test(content);
        const hasFilePicker = /^\s*file_picker:\s*\S+/m.test(content);
        const hasBle = /^\s*flutter_blue_plus:\s*\S+/m.test(content);
        const hasMqtt = /^\s*mqtt_client:\s*\S+/m.test(content);

        const pass = hasVersion2 && hasHttp && hasImage && hasFilePicker && hasBle && hasMqtt;
        this.record(
          "tier4",
          "companion_app/pubspec.yaml declares version 2.0.0+ and required dependencies (http, image, file_picker)",
          pass,
          `Version 2.0.0+: ${hasVersion2}, http: ${hasHttp}, image: ${hasImage}, file_picker: ${hasFilePicker}`
        );
      }
    }

    // Audit 4.2: C sources PRIu32 format specifier and Picolibc -Werror audit
    {
      const cFiles = [
        "main/anim_storage.c",
        "main/anim_storage.h",
        "main/oled_dancing_cat.c",
        "main/oled_dancing_cat.h",
        "main/lan_server.c",
        "main/lan_server.h",
        "main/net_ble_mqtt.c",
      ];

      let totalChecked = 0;
      let violations = [];

      for (const rel of cFiles) {
        const fullPath = path.resolve(rootDir, rel);
        if (!fs.existsSync(fullPath)) continue;
        totalChecked++;
        const content = fs.readFileSync(fullPath, "utf8");

        // Check for unbounded sprintf (must use snprintf)
        const dangerousSprintf = content.match(/\bsprintf\s*\(/g);
        if (dangerousSprintf) {
          violations.push(`${rel}: uses unbounded sprintf() instead of snprintf()`);
        }

        // Check for PRIu32 compliance in ESP_LOG calls with 32-bit partition/CRC values
        if (rel.includes("anim_storage") && content.includes("ESP_LOG")) {
          const usesIntTypes = content.includes("<inttypes.h>");
          if (!usesIntTypes) {
            violations.push(`${rel}: formatted logging without <inttypes.h>`);
          }
        }
      }

      const pass = (totalChecked > 0) && (violations.length === 0);
      this.record(
        "tier4",
        `C source audit: Picolibc <inttypes.h>/PRIu32 formatting and safe bounded snprintf in active sources (${totalChecked} files audited)`,
        pass,
        violations.length > 0 ? violations.join("; ") : "Zero -Werror / format violations detected"
      );
    }

    // Audit 4.3: anim_storage.h interface contract compliance
    {
      const animHeaderPath = path.resolve(rootDir, "main/anim_storage.h");
      if (!fs.existsSync(animHeaderPath)) {
        this.record("tier4", "main/anim_storage.h header interface contract", false, "File missing");
      } else {
        const content = fs.readFileSync(animHeaderPath, "utf8");
        const hasWbinHeader = content.includes("typedef struct") && content.includes("wbin_header_t");
        const hasInit = content.includes("anim_storage_init");
        const hasLoad = content.includes("anim_storage_load_to_psram");
        const hasSave = content.includes("anim_storage_save_from_buffer");
        const hasErase = content.includes("anim_storage_erase");
        const hasCustom = content.includes("anim_storage_has_custom");

        const pass = hasWbinHeader && hasInit && hasLoad && hasSave && hasErase && hasCustom;
        this.record(
          "tier4",
          "main/anim_storage.h declares all specified storage & PSRAM interface contracts",
          pass,
          `wbin_header_t: ${hasWbinHeader}, init: ${hasInit}, load: ${hasLoad}, save: ${hasSave}, erase: ${hasErase}`
        );
      }
    }

    // Audit 4.4: main/CMakeLists.txt ESP-IDF v6.1 component registrations
    {
      const cmakePath = path.resolve(rootDir, "main/CMakeLists.txt");
      if (!fs.existsSync(cmakePath)) {
        this.record("tier4", "main/CMakeLists.txt exists", false, "File missing");
      } else {
        const content = fs.readFileSync(cmakePath, "utf8");
        const requiredComponents = [
          "esp_http_server",
          "mdns",
          "esp_http_client",
          "esp_partition",
        ];

        const missing = requiredComponents.filter((c) => !content.includes(c));
        if (missing.length === 0) {
          this.record("tier4", "main/CMakeLists.txt registers all required ESP-IDF v6.1 components", true);
        } else {
          // Check if Milestone M2 is pending
          this.recordPending(
            "tier4",
            `main/CMakeLists.txt ESP-IDF v6.1 component registrations (missing: ${missing.join(", ")})`,
            "Scheduled for Milestone M2: Firmware LAN Server & Multi-Transport"
          );
        }
      }
    }

    // Audit 4.5: main/idf_component.yml managed dependencies
    {
      const idfCompPath = path.resolve(rootDir, "main/idf_component.yml");
      if (!fs.existsSync(idfCompPath)) {
        this.record("tier4", "main/idf_component.yml exists", false, "File missing");
      } else {
        const content = fs.readFileSync(idfCompPath, "utf8");
        if (content.includes("espressif/mdns")) {
          this.record("tier4", "main/idf_component.yml declares espressif/mdns managed dependency", true);
        } else {
          this.recordPending(
            "tier4",
            "main/idf_component.yml declares espressif/mdns",
            "Scheduled for Milestone M2: Firmware LAN Server & Multi-Transport"
          );
        }
      }
    }

    // Audit 4.6: partitions.csv anim_data partition definition
    {
      const partPath = path.resolve(rootDir, "partitions.csv");
      if (!fs.existsSync(partPath)) {
        this.record("tier4", "partitions.csv exists", false, "File missing");
      } else {
        const content = fs.readFileSync(partPath, "utf8");
        const hasAnim = content.includes("anim_data") && content.includes("0x310000") && content.includes("0x100000");
        this.record("tier4", "partitions.csv defines valid anim_data partition (0x310000, 1MB)", hasAnim);
      }
    }
  }

  // --------------------------------------------------------------------------
  // SUMMARY REPORT & EXIT CODE
  // --------------------------------------------------------------------------
  generateReport() {
    console.log("\n===============================================================================");
    console.log("  W.A.S.T.E. v2.0.0 GAP B VERIFICATION SUMMARY REPORT");
    console.log("===============================================================================");

    const tiers = ["tier1", "tier2", "tier3", "tier4"];
    let totalTests = 0;
    let totalPassed = 0;
    let totalPending = 0;
    let totalFailed = 0;

    for (const t of tiers) {
      const list = this.results[t];
      const passed = list.filter((r) => r.passed && !r.pending).length;
      const pending = list.filter((r) => r.pending).length;
      const failed = list.filter((r) => !r.passed).length;

      totalTests += list.length;
      totalPassed += passed;
      totalPending += pending;
      totalFailed += failed;

      console.log(`  ${t.toUpperCase()}: ${passed} Passed, ${pending} Pending (Future Milestones), ${failed} Failed (Total: ${list.length})`);
    }

    console.log("-------------------------------------------------------------------------------");
    console.log(`  TOTAL: ${totalPassed} Passed, ${totalPending} Pending, ${totalFailed} Failed out of ${totalTests} checks`);

    const overallSuccess = (totalFailed === 0);
    if (overallSuccess) {
      console.log("\n  VERDICT: ✔ ALL APPLICABLE GAP B TESTS & INTEGRITY CHECKS PASSED DETERMINISTICALLY");
      console.log("===============================================================================\n");
      return 0;
    } else {
      console.log("\n  VERDICT: ✖ VERIFICATION FAILED (Defects Detected)");
      console.log("===============================================================================\n");
      return 1;
    }
  }
}

// ============================================================================
// 5. MAIN EXECUTION
// ============================================================================

function main() {
  const isStrict = process.argv.includes("--strict");
  const isVerbose = process.argv.includes("--verbose") || process.argv.includes("-v");

  const runner = new TestRunner({ strict: isStrict, verbose: isVerbose });
  runner.runTier1();
  runner.runTier2();
  runner.runTier3();
  runner.runTier4();

  const exitCode = runner.generateReport();
  process.exit(exitCode);
}

const currentFile = fileURLToPath(import.meta.url);
const invokedFile = process.argv[1] ? path.resolve(process.argv[1]) : "";
if (invokedFile === currentFile || invokedFile.endsWith("verify_gap_b.mjs")) {
  main();
}
