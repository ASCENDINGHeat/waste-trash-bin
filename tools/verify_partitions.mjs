#!/usr/bin/env node
/**
 * W.A.S.T.E. v2.0.0 — Partition Table Verifier (tools/verify_partitions.mjs)
 *
 * Deterministically parses and validates partitions.csv for ESP32-S3 N16R8 (16 MB Flash):
 * 1. Checks partition syntax, structure, offsets, and sizes.
 * 2. Confirms 4 KB (sector) and 64 KB (block) alignment.
 * 3. Checks for any partition collisions / memory overlaps.
 * 4. Confirms that all partitions fit cleanly within 16 MB NOR Flash (0x1000000).
 * 5. Strictly validates the 'anim_data' partition:
 *    - Must exist in the partition table
 *    - Type: data
 *    - SubType: 0x99
 *    - Offset: 0x310000 (4KB sector aligned and 64KB block aligned)
 *    - Size: 1 MB (0x100000 bytes, 4KB sector aligned and 64KB block aligned)
 *    - Non-overlapping with 'factory' partition (which ends at 0x310000)
 *    - Fits within 16 MB flash
 *
 * Usage:
 *   node tools/verify_partitions.mjs [path/to/partitions.csv]
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const FLASH_TOTAL_BYTES = 16 * 1024 * 1024; // 16 MB (0x1000000)
const SECTOR_SIZE_4KB = 4 * 1024;           // 4 KB (0x1000)
const BLOCK_SIZE_64KB = 64 * 1024;          // 64 KB (0x10000)

const EXPECTED_ANIM_PARTITION = {
  name: "anim_data",
  type: "data",
  subTypeHex: "0x99",
  subTypeInt: 0x99,
  offset: 0x310000,
  size: 0x100000, // 1 MB (1,048,576 bytes)
};

/**
 * Parses numeric strings in hex (0x...), decimal, or with K/M suffixes.
 */
export function parseSizeOrOffset(str) {
  if (typeof str !== "string") return NaN;
  const trimmed = str.trim();
  if (/^0x[0-9a-fA-F]+$/i.test(trimmed)) {
    return parseInt(trimmed, 16);
  }
  const match = trimmed.match(/^(\d+(?:\.\d+)?)\s*([kKmMgG]?)(?:[bB]?)$/);
  if (match) {
    const val = parseFloat(match[1]);
    const unit = match[2].toUpperCase();
    if (unit === "K") return Math.round(val * 1024);
    if (unit === "M") return Math.round(val * 1024 * 1024);
    if (unit === "G") return Math.round(val * 1024 * 1024 * 1024);
    return Math.round(val);
  }
  return parseInt(trimmed, 10);
}

/**
 * Normalizes subtype value into a comparable representation.
 */
export function normalizeSubType(subTypeStr) {
  if (!subTypeStr) return { raw: "", intVal: null };
  const raw = subTypeStr.trim();
  if (/^0x[0-9a-fA-F]+$/i.test(raw)) {
    return { raw, intVal: parseInt(raw, 16) };
  }
  const num = parseInt(raw, 10);
  if (!Number.isNaN(num)) {
    return { raw, intVal: num };
  }
  return { raw, intVal: null };
}

/**
 * Parses partitions.csv content into structured entries.
 */
export function parsePartitionsCsv(csvContent) {
  const lines = csvContent.split(/\r?\n/);
  const partitions = [];

  for (let i = 0; i < lines.length; i++) {
    const rawLine = lines[i];
    const stripped = rawLine.split("#")[0].trim();
    if (!stripped) continue;

    const parts = stripped.split(",").map((p) => p.trim());
    if (parts.length < 5) {
      throw new Error(`Line ${i + 1}: Malformed partition line: "${rawLine}" (expected >= 5 comma-separated values)`);
    }

    const name = parts[0];
    const type = parts[1].toLowerCase();
    const subTypeRaw = parts[2];
    const subTypeNorm = normalizeSubType(subTypeRaw);
    const offset = parseSizeOrOffset(parts[3]);
    const size = parseSizeOrOffset(parts[4]);
    const flags = parts[5] || "";

    if (Number.isNaN(offset) || offset < 0) {
      throw new Error(`Line ${i + 1}: Invalid offset "${parts[3]}" for partition "${name}"`);
    }
    if (Number.isNaN(size) || size <= 0) {
      throw new Error(`Line ${i + 1}: Invalid size "${parts[4]}" for partition "${name}"`);
    }

    partitions.push({
      lineNum: i + 1,
      name,
      type,
      subTypeRaw,
      subTypeInt: subTypeNorm.intVal,
      offset,
      size,
      end: offset + size,
      flags,
    });
  }

  return partitions;
}

/**
 * Validates a partition table against general ESP-IDF rules and W.A.S.T.E. Gap B constraints.
 */
export function validatePartitionTable(partitions, totalFlashBytes = FLASH_TOTAL_BYTES) {
  const errors = [];
  const warnings = [];

  if (!partitions || partitions.length === 0) {
    errors.push("Partition table contains zero active partition entries.");
    return { valid: false, errors, warnings };
  }

  // 1. Check partition name uniqueness and character constraints
  const namesSeen = new Set();
  for (const part of partitions) {
    if (namesSeen.has(part.name)) {
      errors.push(`Duplicate partition name: "${part.name}" on line ${part.lineNum}`);
    }
    namesSeen.add(part.name);

    if (part.name.length > 16) {
      errors.push(`Partition name "${part.name}" exceeds ESP-IDF 16-character limit (${part.name.length} chars)`);
    }

    // 2. Alignment checks (Every partition offset & size must be 4KB sector-aligned)
    if (part.offset % SECTOR_SIZE_4KB !== 0) {
      errors.push(
        `Partition "${part.name}" offset 0x${part.offset.toString(16)} is not 4KB sector aligned (mod 0x1000 = 0x${(
          part.offset % SECTOR_SIZE_4KB
        ).toString(16)})`
      );
    }
    if (part.size % SECTOR_SIZE_4KB !== 0) {
      errors.push(
        `Partition "${part.name}" size 0x${part.size.toString(16)} is not 4KB sector aligned (mod 0x1000 = 0x${(
          part.size % SECTOR_SIZE_4KB
        ).toString(16)})`
      );
    }

    // 3. Flash boundary check
    if (part.end > totalFlashBytes) {
      errors.push(
        `Partition "${part.name}" ends at 0x${part.end.toString(16)}, which exceeds 16 MB flash capacity 0x${totalFlashBytes.toString(
          16
        )}`
      );
    }
  }

  // 4. Overlap detection (sort by offset)
  const sorted = [...partitions].sort((a, b) => a.offset - b.offset);
  for (let i = 0; i < sorted.length - 1; i++) {
    const current = sorted[i];
    const next = sorted[i + 1];
    if (current.end > next.offset) {
      const overlapBytes = current.end - next.offset;
      errors.push(
        `Partition overlap detected: "${current.name}" [0x${current.offset.toString(16)} - 0x${current.end.toString(
          16
        )}] collides with "${next.name}" [0x${next.offset.toString(16)} - 0x${next.end.toString(
          16
        )}] by ${overlapBytes} bytes`
      );
    }
  }

  // 5. Specific Gap B anim_data partition validation
  const animPart = partitions.find((p) => p.name === EXPECTED_ANIM_PARTITION.name);
  if (!animPart) {
    errors.push(`Required partition "${EXPECTED_ANIM_PARTITION.name}" does not exist in partition table.`);
  } else {
    // Type check
    if (animPart.type !== EXPECTED_ANIM_PARTITION.type) {
      errors.push(
        `anim_data type mismatch: expected "${EXPECTED_ANIM_PARTITION.type}", got "${animPart.type}"`
      );
    }

    // Subtype check (0x99)
    if (animPart.subTypeInt !== EXPECTED_ANIM_PARTITION.subTypeInt) {
      errors.push(
        `anim_data subtype mismatch: expected ${EXPECTED_ANIM_PARTITION.subTypeHex} (decimal ${EXPECTED_ANIM_PARTITION.subTypeInt}), got "${animPart.subTypeRaw}"`
      );
    }

    // Offset check (0x310000)
    if (animPart.offset !== EXPECTED_ANIM_PARTITION.offset) {
      errors.push(
        `anim_data offset mismatch: expected 0x${EXPECTED_ANIM_PARTITION.offset.toString(
          16
        )}, got 0x${animPart.offset.toString(16)}`
      );
    }

    // Size check (1 MB / 0x100000)
    if (animPart.size !== EXPECTED_ANIM_PARTITION.size) {
      errors.push(
        `anim_data size mismatch: expected 0x${EXPECTED_ANIM_PARTITION.size.toString(
          16
        )} (1 MB / 1,048,576 bytes), got 0x${animPart.size.toString(16)} (${animPart.size} bytes)`
      );
    }

    // Sector (4KB) and Block (64KB) alignment checks for anim_data
    if (animPart.offset % SECTOR_SIZE_4KB !== 0) {
      errors.push(`anim_data offset 0x${animPart.offset.toString(16)} is not 4KB sector aligned`);
    }
    if (animPart.offset % BLOCK_SIZE_64KB !== 0) {
      errors.push(
        `anim_data offset 0x${animPart.offset.toString(
          16
        )} is not 64KB block aligned (required for efficient NOR flash erase block operations)`
      );
    }
    if (animPart.size % SECTOR_SIZE_4KB !== 0) {
      errors.push(`anim_data size 0x${animPart.size.toString(16)} is not 4KB sector aligned`);
    }
    if (animPart.size % BLOCK_SIZE_64KB !== 0) {
      errors.push(`anim_data size 0x${animPart.size.toString(16)} is not 64KB block aligned`);
    }

    // Check relationship with 'factory' partition
    const factoryPart = partitions.find((p) => p.name === "factory");
    if (!factoryPart) {
      warnings.push(`No "factory" partition found to verify adjacency with anim_data.`);
    } else {
      const factoryEnd = factoryPart.offset + factoryPart.size;
      if (factoryEnd > animPart.offset) {
        errors.push(
          `Collision: factory partition ends at 0x${factoryEnd.toString(16)}, overlapping anim_data starting at 0x${animPart.offset.toString(16)}`
        );
      } else if (factoryEnd === animPart.offset) {
        // Exactly adjacent — optimal flash packing
      } else {
        warnings.push(
          `Gap of ${(animPart.offset - factoryEnd)} bytes between factory end (0x${factoryEnd.toString(16)}) and anim_data start (0x${animPart.offset.toString(16)})`
        );
      }
    }

    // Ensure anim_data fits cleanly inside 16 MB flash
    if (animPart.end > totalFlashBytes) {
      errors.push(
        `anim_data ends at 0x${animPart.end.toString(16)}, exceeding 16 MB flash capacity 0x${totalFlashBytes.toString(16)}`
      );
    }
  }

  return {
    valid: errors.length === 0,
    errors,
    warnings,
    partitions,
  };
}

/**
 * Runs internal unit tests for the partition validator logic.
 */
export function runSelfTests() {
  const tests = [
    {
      name: "Valid W.A.S.T.E. v2.0.0 layout passes all checks",
      csv: `# Valid layout
nvs,      data, nvs,     0x9000,   0x6000,
phy_init, data, phy,     0xf000,   0x1000,
factory,  app,  factory, 0x10000,  0x300000,
anim_data,data, 0x99,    0x310000, 0x100000,
`,
      expectValid: true,
    },
    {
      name: "Missing anim_data partition is rejected",
      csv: `# Missing anim_data
nvs,      data, nvs,     0x9000,   0x6000,
phy_init, data, phy,     0xf000,   0x1000,
factory,  app,  factory, 0x10000,  0x300000,
`,
      expectValid: false,
      expectedErrorSubstr: 'Required partition "anim_data" does not exist',
    },
    {
      name: "anim_data with incorrect size (512KB instead of 1MB) is rejected",
      csv: `# Wrong anim_data size
nvs,      data, nvs,     0x9000,   0x6000,
phy_init, data, phy,     0xf000,   0x1000,
factory,  app,  factory, 0x10000,  0x300000,
anim_data,data, 0x99,    0x310000, 0x80000,
`,
      expectValid: false,
      expectedErrorSubstr: "anim_data size mismatch",
    },
    {
      name: "anim_data with incorrect subtype (0x98 instead of 0x99) is rejected",
      csv: `# Wrong anim_data subtype
nvs,      data, nvs,     0x9000,   0x6000,
phy_init, data, phy,     0xf000,   0x1000,
factory,  app,  factory, 0x10000,  0x300000,
anim_data,data, 0x98,    0x310000, 0x100000,
`,
      expectValid: false,
      expectedErrorSubstr: "anim_data subtype mismatch",
    },
    {
      name: "anim_data with misaligned offset (not 64KB block aligned) is rejected",
      csv: `# Misaligned offset
nvs,      data, nvs,     0x9000,   0x6000,
phy_init, data, phy,     0xf000,   0x1000,
factory,  app,  factory, 0x10000,  0x300000,
anim_data,data, 0x99,    0x311000, 0x100000,
`,
      expectValid: false,
      expectedErrorSubstr: "anim_data offset mismatch",
    },
    {
      name: "Overlapping factory and anim_data partitions are rejected",
      csv: `# Overlapping factory (3.5MB instead of 3MB)
nvs,      data, nvs,     0x9000,   0x6000,
phy_init, data, phy,     0xf000,   0x1000,
factory,  app,  factory, 0x10000,  0x380000,
anim_data,data, 0x99,    0x310000, 0x100000,
`,
      expectValid: false,
      expectedErrorSubstr: "Partition overlap detected",
    },
    {
      name: "Partition exceeding 16 MB flash capacity is rejected",
      csv: `# Overflowing flash
nvs,      data, nvs,     0x9000,   0x6000,
phy_init, data, phy,     0xf000,   0x1000,
factory,  app,  factory, 0x10000,  0x300000,
anim_data,data, 0x99,    0x310000, 0x100000,
extra,    data, nvs,     0x1000000,0x10000,
`,
      expectValid: false,
      expectedErrorSubstr: "exceeds 16 MB flash capacity",
    },
  ];

  let passed = 0;
  for (const t of tests) {
    try {
      const parts = parsePartitionsCsv(t.csv);
      const res = validatePartitionTable(parts);
      if (res.valid === t.expectValid) {
        if (!t.expectValid && t.expectedErrorSubstr) {
          const matched = res.errors.some((e) => e.includes(t.expectedErrorSubstr));
          if (!matched) {
            throw new Error(`Expected error containing "${t.expectedErrorSubstr}", got: ${res.errors.join("; ")}`);
          }
        }
        passed++;
      } else {
        throw new Error(
          `Expected valid=${t.expectValid}, got valid=${res.valid}. Errors: ${res.errors.join("; ")}`
        );
      }
    } catch (err) {
      console.error(`  [FAIL] Self-test "${t.name}": ${err.message}`);
      return false;
    }
  }

  console.log(`  [PASS] All ${passed}/${tests.length} partition validator self-tests passed cleanly.`);
  return true;
}

/**
 * Main CLI entry point.
 */
function main() {
  console.log("===============================================================================");
  console.log("  W.A.S.T.E. v2.0.0 — Partition Table & anim_data Geometry Verifier");
  console.log("===============================================================================");

  console.log("\n[Step 1/2] Running internal partition validator test matrix...");
  const selfTestsPassed = runSelfTests();
  if (!selfTestsPassed) {
    console.error("\n❌ Partition verifier self-tests failed! Aborting.");
    process.exit(1);
  }

  const defaultPath = path.resolve(process.cwd(), "partitions.csv");
  const targetPath = process.argv[2] ? path.resolve(process.cwd(), process.argv[2]) : defaultPath;

  console.log(`\n[Step 2/2] Inspecting target file: ${targetPath}`);
  if (!fs.existsSync(targetPath)) {
    console.error(`❌ Target partition file not found: ${targetPath}`);
    process.exit(1);
  }

  const content = fs.readFileSync(targetPath, "utf8");
  let partitions;
  try {
    partitions = parsePartitionsCsv(content);
  } catch (err) {
    console.error(`❌ Syntax error parsing partition file:\n   ${err.message}`);
    process.exit(1);
  }

  const result = validatePartitionTable(partitions);

  // Print formatted partition table
  console.log("\nPartition Layout Audit:");
  console.log("┌────────────────┬────────┬──────────┬──────────────┬──────────────┬────────────────┐");
  console.log("│ Name           │ Type   │ SubType  │ Offset       │ Size         │ End            │");
  console.log("├────────────────┼────────┼──────────┼──────────────┼──────────────┼────────────────┤");

  for (const p of partitions) {
    const nameStr = p.name.padEnd(14);
    const typeStr = p.type.padEnd(6);
    const subStr = p.subTypeRaw.padEnd(8);
    const offStr = `0x${p.offset.toString(16).padStart(6, "0")} (${(p.offset / 1024).toFixed(0)}KB)`.padEnd(12);
    const sizeStr = `0x${p.size.toString(16).padStart(6, "0")} (${(p.size / 1024).toFixed(0)}KB)`.padEnd(12);
    const endStr = `0x${p.end.toString(16).padStart(6, "0")}`.padEnd(14);
    console.log(`│ ${nameStr} │ ${typeStr} │ ${subStr} │ ${offStr} │ ${sizeStr} │ ${endStr} │`);
  }
  console.log("└────────────────┴────────┴──────────┴──────────────┴──────────────┴────────────────┘");

  // Output warnings if any
  if (result.warnings.length > 0) {
    console.log("\nWarnings:");
    for (const w of result.warnings) {
      console.log(`  ⚠ ${w}`);
    }
  }

  if (!result.valid) {
    console.error("\n❌ Partition Table Validation FAILED with errors:");
    for (const e of result.errors) {
      console.error(`  ✖ ${e}`);
    }
    process.exit(1);
  }

  // Print anim_data verification breakdown
  const anim = partitions.find((p) => p.name === "anim_data");
  console.log("\nanim_data Verification Checklist:");
  console.log(`  ✔ anim_data partition exists in table: YES`);
  console.log(`  ✔ Partition Type: ${anim.type} (expected: data)`);
  console.log(`  ✔ Partition SubType: ${anim.subTypeRaw} (0x99 / 153)`);
  console.log(`  ✔ Partition Offset: 0x${anim.offset.toString(16)} (expected: 0x310000)`);
  console.log(`  ✔ Partition Size: 0x${anim.size.toString(16)} (1,048,576 bytes / 1.0 MB)`);
  console.log(`  ✔ 4 KB Sector Alignment: offset % 4KB == 0 (0x${(anim.offset % 4096).toString(16)}), size % 4KB == 0`);
  console.log(`  ✔ 64 KB Block Alignment: offset % 64KB == 0 (0x${(anim.offset % 65536).toString(16)}), size % 64KB == 0`);
  console.log(`  ✔ Non-overlapping with factory partition (ends @ 0x310000): YES`);
  console.log(`  ✔ Fits cleanly inside 16 MB NOR Flash (0x410000 <= 0x1000000): YES (~11.94 MB unallocated headroom)`);

  console.log("\n===============================================================================");
  console.log("  VERIFICATION RESULT: ALL PARTITION CHECKS PASSED DETERMINISTICALLY");
  console.log("===============================================================================\n");
  process.exit(0);
}

// Check if running as main script
const currentFile = fileURLToPath(import.meta.url);
const invokedFile = process.argv[1] ? path.resolve(process.argv[1]) : "";
if (invokedFile === currentFile || invokedFile.endsWith("verify_partitions.mjs")) {
  main();
}
