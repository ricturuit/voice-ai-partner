"use strict";

const fs = require("fs");
const path = require("path");
const yaml = require("js-yaml");

const ROOT = path.resolve(__dirname, "..", "..");
const TAXONOMY_DIR = path.join(ROOT, "taxonomy");
const DICTIONARY_DIR = path.join(ROOT, "dictionary");
const GENERATED_DIR = path.join(ROOT, "generated");

const RECORD_FIELDS = ["id", "term", "reading", "category", "tags", "aliases"];
const REQUIRED_RECORD_FIELDS = ["id", "term", "reading", "category"];
// Hiragana, katakana, and the prolonged sound mark only — see
// taxonomy/pronunciation_rules.md §1. No romaji, kanji, or punctuation.
const READING_PATTERN = /^[ぁ-ゖァ-ヺー]+$/u;

function loadYaml(filePath) {
  const raw = fs.readFileSync(filePath, "utf8");
  return yaml.load(raw);
}

function loadTaxonomy() {
  const categoriesDoc = loadYaml(path.join(TAXONOMY_DIR, "categories.yaml"));
  const tagsDoc = loadYaml(path.join(TAXONOMY_DIR, "tags.yaml"));

  const categories = new Map();
  for (const entry of categoriesDoc.categories || []) {
    categories.set(entry.id, entry);
  }

  const tags = new Map();
  for (const entry of tagsDoc.tags || []) {
    tags.set(entry.id, entry);
  }

  return { categories, tags };
}

// Returns [{ record, file }] — file is the dictionary/*.yaml basename (no
// extension), which registration_rules.md requires to equal the record's
// own `category` field.
function loadDictionaryEntries() {
  if (!fs.existsSync(DICTIONARY_DIR)) return [];

  const entries = [];
  const files = fs
    .readdirSync(DICTIONARY_DIR)
    .filter((name) => name.endsWith(".yaml") || name.endsWith(".yml"))
    .sort();

  for (const fileName of files) {
    const filePath = path.join(DICTIONARY_DIR, fileName);
    const categoryFromFile = fileName.replace(/\.ya?ml$/, "");
    const records = loadYaml(filePath) || [];
    if (!Array.isArray(records)) {
      throw new Error(`${fileName}: トップレベルはレコードの配列である必要があります`);
    }
    for (const record of records) {
      entries.push({ record, sourceFile: fileName, categoryFromFile });
    }
  }

  return entries;
}

// Returns an array of human-readable error strings. Empty array == valid.
function validate(taxonomy, entries) {
  const errors = [];
  const idsSeen = new Map(); // id -> sourceFile
  // term/alias matching is case-insensitive on purpose — TTS substitution
  // is typically applied case-insensitively too, and two records that only
  // differ by case would silently race against each other at match time.
  const surfaceFormsSeen = new Map(); // lowercased term/alias -> { kind, owner }

  for (const { record, sourceFile, categoryFromFile } of entries) {
    const where = `${sourceFile} (id: ${record && record.id})`;

    if (record === null || typeof record !== "object" || Array.isArray(record)) {
      errors.push(`${sourceFile}: レコードはオブジェクトである必要があります: ${JSON.stringify(record)}`);
      continue;
    }

    // 未定義フィールドの禁止 — registration_rules.md §3
    const unknownFields = Object.keys(record).filter((k) => !RECORD_FIELDS.includes(k));
    if (unknownFields.length > 0) {
      errors.push(`${where}: 未定義のフィールドがあります: ${unknownFields.join(", ")}`);
    }

    for (const field of REQUIRED_RECORD_FIELDS) {
      if (!record[field] || typeof record[field] !== "string" || record[field].trim() === "") {
        errors.push(`${where}: 必須フィールド "${field}" が空です`);
      }
    }

    if (record.tags !== undefined && !Array.isArray(record.tags)) {
      errors.push(`${where}: "tags" は配列である必要があります`);
    }
    if (record.aliases !== undefined && !Array.isArray(record.aliases)) {
      errors.push(`${where}: "aliases" は配列である必要があります`);
    }

    if (record.id) {
      if (idsSeen.has(record.id)) {
        errors.push(`${where}: id "${record.id}" が ${idsSeen.get(record.id)} と重複しています`);
      } else {
        idsSeen.set(record.id, sourceFile);
      }
    }

    if (record.category) {
      if (!taxonomy.categories.has(record.category)) {
        errors.push(`${where}: 未定義のカテゴリ "${record.category}" が指定されています`);
      }
      if (record.category !== categoryFromFile) {
        errors.push(
          `${where}: ファイル名(${categoryFromFile})とレコードの category (${record.category}) が一致しません`,
        );
      }
    }

    for (const tagId of record.tags || []) {
      if (!taxonomy.tags.has(tagId)) {
        errors.push(`${where}: 未定義のタグ "${tagId}" が指定されています`);
      }
    }

    if (record.reading && !READING_PATTERN.test(record.reading)) {
      errors.push(
        `${where}: "reading" (${record.reading}) に平仮名・片仮名・長音記号以外の文字が含まれています`,
      );
    }

    const surfaceForms = [
      ...(record.term ? [{ value: record.term, kind: "term" }] : []),
      ...((record.aliases || []).map((a) => ({ value: a, kind: "alias" }))),
    ];
    for (const { value, kind } of surfaceForms) {
      const key = value.toLowerCase();
      const existing = surfaceFormsSeen.get(key);
      if (existing) {
        errors.push(
          `${where}: ${kind} "${value}" が ${existing.owner} の ${existing.kind} "${existing.value}" と衝突しています`,
        );
      } else {
        surfaceFormsSeen.set(key, { value, kind, owner: where });
      }
    }
  }

  return errors;
}

module.exports = {
  ROOT,
  TAXONOMY_DIR,
  DICTIONARY_DIR,
  GENERATED_DIR,
  RECORD_FIELDS,
  loadTaxonomy,
  loadDictionaryEntries,
  validate,
};
