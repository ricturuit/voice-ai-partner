#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const {
  ROOT,
  GENERATED_DIR,
  loadTaxonomy,
  loadDictionaryEntries,
  validate,
} = require("./lib/dictionary");

// The actual consumer: infra/lambda/conversation/index.js. That Lambda's
// CDK asset is a plain directory zip (`Code.fromAsset('lambda/conversation')`,
// no bundler step), so unlike generated/ (gitignored build output) this copy
// must be committed — it's what toTtsText() reads via a plain require() at
// cold start. Keep in sync by running this script after editing dictionary/
// and redeploying.
const LAMBDA_LOOKUP_PATH = path.join(
  ROOT, "..", "..", "infra", "lambda", "conversation", "pronunciation-lookup.json",
);

function main() {
  const taxonomy = loadTaxonomy();
  const entries = loadDictionaryEntries();
  const errors = validate(taxonomy, entries);

  if (errors.length > 0) {
    console.error(`✗ build: 検証エラーのため生成を中止しました(${errors.length} 件)\n`);
    for (const message of errors) {
      console.error(`  - ${message}`);
    }
    console.error("\nnpm run validate で詳細を確認してください。");
    process.exitCode = 1;
    return;
  }

  const records = entries
    .map(({ record }) => record)
    .sort((a, b) => (a.category === b.category ? a.id.localeCompare(b.id) : a.category.localeCompare(b.category)));

  const generatedAt = new Date().toISOString();

  const dictionaryOut = {
    generatedAt,
    recordCount: records.length,
    records,
  };

  // Flat term/alias -> reading map — the form a simple TTS text-substitution
  // step (like infra/lambda/conversation/index.js's toTtsText()) can consume
  // directly, without needing to understand categories/tags. Kept separate
  // from dictionary.json (the full structured data) so a future
  // provider-specific adapter still has access to id/category/tags without
  // re-deriving them from the lookup map.
  const lookup = {};
  for (const record of records) {
    lookup[record.term] = record.reading;
    for (const alias of record.aliases || []) {
      lookup[alias] = record.reading;
    }
  }
  const lookupOut = {
    generatedAt,
    entryCount: Object.keys(lookup).length,
    lookup,
  };

  fs.mkdirSync(GENERATED_DIR, { recursive: true });
  fs.writeFileSync(
    path.join(GENERATED_DIR, "dictionary.json"),
    JSON.stringify(dictionaryOut, null, 2) + "\n",
  );
  fs.writeFileSync(
    path.join(GENERATED_DIR, "lookup.json"),
    JSON.stringify(lookupOut, null, 2) + "\n",
  );
  fs.writeFileSync(LAMBDA_LOOKUP_PATH, JSON.stringify(lookupOut, null, 2) + "\n");

  const byCategory = new Map();
  for (const record of records) {
    byCategory.set(record.category, (byCategory.get(record.category) || 0) + 1);
  }

  console.log(`✓ build: ${records.length} 件のレコードから generated/ を再生成しました`);
  for (const [category, count] of [...byCategory.entries()].sort()) {
    console.log(`  - ${category}: ${count} 件`);
  }
  console.log("  -> generated/dictionary.json");
  console.log("  -> generated/lookup.json");
  console.log(`  -> ${path.relative(path.join(ROOT, "..", ".."), LAMBDA_LOOKUP_PATH)}`);
}

main();
