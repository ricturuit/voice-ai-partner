#!/usr/bin/env node
"use strict";

const { loadTaxonomy, loadDictionaryEntries, validate } = require("./lib/dictionary");

function main() {
  const taxonomy = loadTaxonomy();
  const entries = loadDictionaryEntries();
  const errors = validate(taxonomy, entries);

  if (errors.length > 0) {
    console.error(`✗ validate: ${errors.length} 件のエラーがあります\n`);
    for (const message of errors) {
      console.error(`  - ${message}`);
    }
    process.exitCode = 1;
    return;
  }

  console.log(`✓ validate: ${entries.length} 件のレコードを確認しました(エラーなし)`);
}

main();
