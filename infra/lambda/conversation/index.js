const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const {
  DynamoDBDocumentClient,
  QueryCommand,
  PutCommand,
} = require("@aws-sdk/lib-dynamodb");
const { S3Client, PutObjectCommand, GetObjectCommand } = require("@aws-sdk/client-s3");
const { getSignedUrl } = require("@aws-sdk/s3-request-presigner");
const {
  SecretsManagerClient,
  GetSecretValueCommand,
} = require("@aws-sdk/client-secrets-manager");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const ddbClient = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const s3Client = new S3Client({});
const secretsClient = new SecretsManagerClient({});

const TABLE_NAME = process.env.SHORT_TERM_MEMORY_TABLE_NAME;
const BUCKET_NAME = process.env.ARTIFACTS_BUCKET_NAME;
const CLAUDE_MODEL = process.env.CLAUDE_MODEL || "claude-haiku-4-5-20251001";
// Preset ElevenLabs voice, swappable without code changes once a cloned
// voice ID exists (see README.md). Must be a voice already owned by the
// account (GET /v1/voices) — the free plan rejects voice-library IDs
// that haven't been added to the account.
const ELEVENLABS_VOICE_ID = process.env.ELEVENLABS_VOICE_ID || "EXAVITQu4vr4xnSDxMaL";
const ELEVENLABS_MODEL_ID = process.env.ELEVENLABS_MODEL_ID || "eleven_v3";
// eleven_v3 is more expressive than v2 by design, which showed up in testing
// as occasional unwanted mid-reply swings in tone/energy. Raising stability
// (0-1, higher = more consistent/less varied delivery) trades away some of
// that expressiveness for fewer erratic jumps. Starting point pending
// real-device listening feedback — adjust ELEVENLABS_STABILITY without a
// code change if it needs tuning further.
const ELEVENLABS_STABILITY = parseFloat(process.env.ELEVENLABS_STABILITY || "0.6");
const ELEVENLABS_SIMILARITY_BOOST = parseFloat(process.env.ELEVENLABS_SIMILARITY_BOOST || "0.8");
// A previous, much lower value (400) was cutting off replies mid-sentence
// whenever the character legitimately needed more room (e.g. a search
// result). Reply length/brevity is controlled entirely by system-prompt.md's
// "音声会話ルール" section now — this is a generous safety ceiling only
// (bounds worst-case Claude/ElevenLabs cost and latency), not expected to be
// hit in normal conversation.
const CLAUDE_MAX_TOKENS = parseInt(process.env.CLAUDE_MAX_TOKENS || "4096", 10);
// Character persona/style instructions, edited as a standalone file rather
// than an env var (Lambda env vars share a 4KB total budget across all of
// them, too tight for a prompt this size) — edit system-prompt.md and
// redeploy to change how the character speaks.
const SYSTEM_PROMPT = fs.readFileSync(path.join(__dirname, "system-prompt.md"), "utf8");
// English-learning mode's instructions are an *overlay* appended to the base
// character prompt above, never a second standalone copy of it — duplicating
// the persona across two files guarantees they drift apart the first time one
// is edited alone. Everything mode-specific (speak English, difficulty by
// CEFR level, when to switch into explaining grammar, JSON output shape)
// lives in the overlay; everything about who 名取 is stays in the base.
const ENGLISH_MODE_PROMPT = fs.readFileSync(
  path.join(__dirname, "system-prompt-english.md"),
  "utf8",
);
const ENGLISH_MODE = "english_learning";
// CEFR levels this app ladders through, lowest first. Chosen against the
// official CEFR self-assessment grid and MEXT's published CEFR↔英検 mapping:
// A1≈英検3級 (the requested floor), B1 is where unprepared everyday
// conversation becomes possible, B2 is where TV news/current affairs become
// understandable, and C1 is where the grid itself describes using the
// language "for social and professional purposes" (the requested ceiling).
const CEFR_LEVELS = ["A1", "A2", "B1", "B2", "C1"];
const DEFAULT_LEVEL = "A1";
// How many exchanges a level test runs before the verdict must be given.
// The turn number is tracked by the client and the "judge now" instruction is
// injected here, rather than left to the model's own sense of "after a few
// turns" — asked that way it simply keeps chatting: a six-turn trial never
// produced a verdict at all, which would have made levelling up unreachable.
const LEVEL_TEST_TURNS = 5;
// ElevenLabs (and TTS engines generally) frequently misreads English
// acronyms embedded in Japanese text — spelling them out letter-by-letter
// incorrectly rather than using the natural katakana reading. This map is
// applied ONLY to the text sent for speech synthesis, never to the text
// returned to the client, shown in chat, or stored in DynamoDB history —
// so the transcript stays as Claude actually wrote it.
//
// The map itself is generated from docs/pronunciation/ (the maintained
// technical-term + character-pronunciation master, including the "せんせえ"
// → "せんせい" override — see docs/pronunciation/README.md) and this file
// (pronunciation-lookup.json) is a committed copy sitting next to index.js
// so it's picked up by the plain directory zip `Code.fromAsset('lambda/
// conversation')` uses (no bundler step in this stack). After editing
// docs/pronunciation/dictionary/*.yaml, run `npm run build` from
// docs/pronunciation/ to regenerate this file, then redeploy.
const PRONUNCIATION_LOOKUP = JSON.parse(
  fs.readFileSync(path.join(__dirname, "pronunciation-lookup.json"), "utf8"),
).lookup;

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Precompiled once at module load (not per-request), longest term first so
// a multi-word/compound term (e.g. "CI/CD") gets substituted before a
// shorter term it contains (e.g. "CD") has a chance to corrupt the
// substring. Each match is rejected if it immediately touches an ASCII
// letter/digit on either side (so "AI" doesn't fire inside "AIRPORT") —
// using a lookaround instead of \b since \b never matches around Japanese
// characters, and this works uniformly for terms containing regex-special
// characters (C++, .NET, GPT-4.1) once they're escaped.
const TTS_PATTERNS = Object.entries(PRONUNCIATION_LOOKUP)
  .sort(([a], [b]) => b.length - a.length)
  .map(([term, reading]) => ({
    pattern: new RegExp(`(?<![A-Za-z0-9])${escapeRegExp(term)}(?![A-Za-z0-9])`, "g"),
    reading,
  }));

// Strips URLs from the TTS-bound copy only — a spoken-out URL is
// unintelligible, and the chat UI already shows the real link, so the
// visible/returned replyText keeps it untouched (same "TTS-only" rule as
// the pronunciation substitutions above). Runs before those substitutions
// so a URL's path/query segments can't accidentally match a dictionary
// term. See system-prompt.md's "URL(リンク)の扱い" — Claude is told to
// lead into a URL with "→", which this also cleans up once the URL itself
// is gone, and to only include a URL when the user actually asked for one.
function stripUrlsForTts(text) {
  return text
    .replace(/[(（]\s*https?:\/\/[^\s)）]+\s*[)）]/g, "")
    .replace(/https?:\/\/\S+/g, "")
    .replace(/→\s*$/gm, "")
    .replace(/[ \t]{2,}/g, " ")
    .trim();
}

// Hiragana, katakana, or CJK ideographs anywhere in the string.
const JAPANESE_CHARS = /[぀-ゟ゠-ヿ一-鿿]/;

// The pronunciation dictionary exists to make English terms embedded in
// *Japanese* speech read naturally (`AWS` → `エーダブリューエス`). Applied to
// an English sentence it does the opposite — it would replace real English
// words with katakana mid-sentence, so an English reply would be read aloud
// as broken Japanese. Gate it on the text actually being Japanese rather than
// on the request's mode: English-learning mode still answers grammar
// questions in Japanese (where the dictionary should apply), and the check
// stays correct for both modes without either needing to know about the other.
function toTtsText(text) {
  let result = stripUrlsForTts(text);
  if (!JAPANESE_CHARS.test(result)) {
    return result;
  }
  for (const { pattern, reading } of TTS_PATTERNS) {
    result = result.replace(pattern, reading);
  }
  return result;
}

// English-learning mode asks Claude for a JSON object rather than plain text
// (reply + translation + input hints + suggested replies + any test verdict,
// all produced in the one round trip that was already happening). Claude
// sometimes wraps JSON in a ```json fence despite being told not to — this
// project has hit that before — so strip a fence if present, and treat any
// parse failure as "just use the whole thing as the spoken reply" rather
// than failing the request: a turn that loses its translation is a degraded
// turn, but a turn that 500s is a broken conversation.
function parseEnglishModeReply(raw) {
  const fenced = raw.match(/^\s*```(?:json)?\s*\n([\s\S]*?)\n?\s*```\s*$/);
  const candidate = fenced ? fenced[1] : raw;
  let parsed;
  try {
    parsed = JSON.parse(candidate);
  } catch {
    console.warn("English-mode reply was not valid JSON; using it verbatim");
    return { text: raw };
  }
  if (!parsed || typeof parsed.text !== "string" || !parsed.text.trim()) {
    console.warn("English-mode JSON had no usable text field; using raw reply");
    return { text: raw };
  }
  const pairs = (value) =>
    Array.isArray(value)
      ? value
          .filter((v) => v && typeof v.en === "string" && typeof v.ja === "string")
          .map(({ en, ja }) => ({ en, ja }))
      : [];
  const verdict =
    parsed.testResult && typeof parsed.testResult.passed === "boolean"
      ? {
          passed: parsed.testResult.passed,
          comment:
            typeof parsed.testResult.comment === "string" ? parsed.testResult.comment : "",
        }
      : null;
  return {
    text: parsed.text.trim(),
    translation: typeof parsed.translation === "string" ? parsed.translation : null,
    hintWords: pairs(parsed.hintWords),
    suggestedReplies: pairs(parsed.suggestedReplies),
    testResult: verdict,
  };
}

const HISTORY_LIMIT = 20;
const TTL_SECONDS = 6 * 60 * 60;
const AUDIO_URL_EXPIRY_SECONDS = 3600;

// Cached across warm invocations so we don't call Secrets Manager on every request.
const secretCache = new Map();
async function getSecretValue(secretArn) {
  if (secretCache.has(secretArn)) {
    return secretCache.get(secretArn);
  }
  const response = await secretsClient.send(new GetSecretValueCommand({ SecretId: secretArn }));
  secretCache.set(secretArn, response.SecretString);
  return response.SecretString;
}

function respond(statusCode, bodyObj) {
  return {
    statusCode,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(bodyObj),
  };
}

// Per-stage timings for one invocation, logged as a single line at the end.
// Turn latency is the thing users actually feel, and it is made of several
// remote calls whose individual costs are invisible from the outside — the
// last time it needed tuning, the breakdown had to be reconstructed by
// timing each upstream service by hand. Logging it makes the next
// investigation a log query instead.
function createTimer() {
  const start = Date.now();
  let last = start;
  const stages = {};
  return {
    mark(name) {
      const now = Date.now();
      stages[name] = now - last;
      last = now;
    },
    log(extra) {
      console.log(
        "turn timings(ms)",
        JSON.stringify({ ...stages, total: Date.now() - start, ...extra }),
      );
    },
  };
}

exports.handler = async (event) => {
  const timer = createTimer();
  try {
    const providedSecret = (event.headers && event.headers["x-api-secret"]) || "";
    const expectedSecret = await getSecretValue(process.env.SHARED_API_SECRET_ARN);
    if (providedSecret !== expectedSecret) {
      return respond(401, { error: "unauthorized" });
    }

    let body;
    try {
      body = JSON.parse(event.body || "{}");
    } catch {
      return respond(400, { error: "invalid_json" });
    }

    const { sessionId, text } = body;
    if (!sessionId || typeof sessionId !== "string" || !text || typeof text !== "string") {
      return respond(400, { error: "sessionId and text are required" });
    }

    // Both optional — an older client that sends neither keeps the original
    // Japanese-conversation behavior unchanged.
    const isEnglishMode = body.mode === ENGLISH_MODE;
    const level = CEFR_LEVELS.includes(body.level) ? body.level : DEFAULT_LEVEL;
    const isLevelTest = isEnglishMode && body.levelTest === true;
    // 1-based, clamped: a client that loses count can never push the test
    // past its final turn, so a test always terminates in a verdict.
    const levelTestTurn = isLevelTest
      ? Math.min(Math.max(Number(body.levelTestTurn) || 1, 1), LEVEL_TEST_TURNS)
      : 0;

    // 1. Load recent conversation history for this session.
    const historyResult = await ddbClient.send(
      new QueryCommand({
        TableName: TABLE_NAME,
        KeyConditionExpression: "sessionId = :sid",
        ExpressionAttributeValues: { ":sid": sessionId },
        ScanIndexForward: false,
        Limit: HISTORY_LIMIT,
      }),
    );
    const history = (historyResult.Items || []).slice().reverse();
    timer.mark("history");

    const claudeMessages = history.map((item) => ({
      role: item.role,
      content: item.message,
    }));
    claudeMessages.push({ role: "user", content: text });

    // 2. Ask Claude for a reply, with history as context.
    let systemPrompt = SYSTEM_PROMPT;
    if (isEnglishMode) {
      systemPrompt +=
        `\n\n---\n\n${ENGLISH_MODE_PROMPT}\n\n` +
        `## このターンの状態\n\n` +
        `- ユーザーの現在のCEFRレベル: ${level}\n` +
        (isLevelTest
          ? `- **レベルテスト中**(全${LEVEL_TEST_TURNS}ターン中の ${levelTestTurn} ターン目)。\n` +
            (levelTestTurn >= LEVEL_TEST_TURNS
              ? `- **このターンで必ず合否を判定し、\`testResult\` を返すこと。**\n` +
                `- このターンの \`text\` は「テストがここで終わったこと」が伝わる ` +
                `締めくくりの一言にする。**新しい質問を含めてはいけない**` +
                `(質問で終わると、ユーザーはテストが続いていると誤解する)。` +
                `例: \`Okay Sensee, that's the end of the test! Let me tell you how you did.\`\n` +
                `- 細かい講評は \`text\` ではなく \`testResult.comment\` に日本語で書く。\n`
              : `- まだ判定しない。${level} の力を測れる話題で会話を続け、` +
                `\`testResult\` は null にする。\n`)
          : `- 通常の会話中(テストではない)。\`testResult\` は必ず null にする。\n`);
    }
    const claudeApiKey = await getSecretValue(process.env.CLAUDE_API_KEY_SECRET_ARN);
    const claudeResponse = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": claudeApiKey,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: CLAUDE_MODEL,
        max_tokens: CLAUDE_MAX_TOKENS,
        system: systemPrompt,
        messages: claudeMessages,
        // Server-executed — Claude decides on its own whether a given turn
        // needs a search (see system-prompt.md's guidance on when to search
        // vs. answer directly) and, if so, runs it and folds the result
        // into the same response with no extra round trip from this Lambda.
        // Basic (non-dynamic-filtering) variant: CLAUDE_MODEL is Haiku
        // 4.5, which isn't in the model list documented to support the
        // newer dynamic-filtering tool versions.
        //
        // Deliberately off in English-learning mode: that mode needs the
        // reply to be one clean JSON object, and a search turn interleaves
        // extra content blocks (and can end on `pause_turn`) that make that
        // markedly less reliable. Practising conversation doesn't need live
        // facts, so the trade is worth it — revisit if a use case for
        // searching mid-lesson actually appears.
        ...(isEnglishMode
          ? {}
          : { tools: [{ type: "web_search_20250305", name: "web_search", max_uses: 3 }] }),
      }),
    });

    if (!claudeResponse.ok) {
      console.error("Claude API error", claudeResponse.status, await claudeResponse.text());
      return respond(502, { error: "claude_api_error" });
    }

    timer.mark("claude");
    const claudeData = await claudeResponse.json();
    const replyText = (claudeData.content || [])
      .filter((block) => block.type === "text")
      .map((block) => block.text)
      .join("\n")
      .trim();

    if (claudeData.stop_reason === "max_tokens") {
      // Claude hit CLAUDE_MAX_TOKENS before finishing the sentence — the
      // reply below is truncated mid-thought. Logged (not treated as an
      // error) so CLAUDE_MAX_TOKENS can be re-tuned if this shows up often.
      console.warn(
        "Claude reply truncated by max_tokens",
        JSON.stringify({ maxTokens: CLAUDE_MAX_TOKENS, replyLength: replyText.length }),
      );
    } else if (claudeData.stop_reason === "pause_turn") {
      // A web_search turn ran long enough to hit the server-side search
      // loop's own limit. Not resumed here (would need a second request
      // echoing the paused assistant turn back) — logged so this can be
      // revisited if it turns out to happen often with max_uses: 3.
      console.warn("Claude search turn paused (pause_turn)", JSON.stringify({ replyLength: replyText.length }));
    }

    if (!replyText) {
      console.error("Claude API returned no text content", JSON.stringify(claudeData));
      return respond(502, { error: "empty_claude_response" });
    }

    // In English-learning mode the model's raw output is a JSON envelope;
    // everything downstream (TTS, stored history) wants only the spoken
    // reply out of it. In normal mode the raw output *is* the spoken reply.
    const extras = isEnglishMode ? parseEnglishModeReply(replyText) : { text: replyText };
    const spokenText = extras.text;

    // 3. Synthesize speech for the reply via ElevenLabs.
    const elevenLabsApiKey = await getSecretValue(process.env.ELEVENLABS_API_KEY_SECRET_ARN);
    const ttsResponse = await fetch(
      `https://api.elevenlabs.io/v1/text-to-speech/${ELEVENLABS_VOICE_ID}`,
      {
        method: "POST",
        headers: {
          "xi-api-key": elevenLabsApiKey,
          "content-type": "application/json",
          accept: "audio/mpeg",
        },
        body: JSON.stringify({
          text: toTtsText(spokenText),
          model_id: ELEVENLABS_MODEL_ID,
          voice_settings: {
            stability: ELEVENLABS_STABILITY,
            similarity_boost: ELEVENLABS_SIMILARITY_BOOST,
          },
        }),
      },
    );

    if (!ttsResponse.ok) {
      console.error("ElevenLabs API error", ttsResponse.status, await ttsResponse.text());
      return respond(502, { error: "tts_api_error" });
    }

    timer.mark("tts");
    const audioBuffer = Buffer.from(await ttsResponse.arrayBuffer());

    // 4. Store the audio in S3 and issue a short-lived signed URL for it.
    const audioKey = `audio/${sessionId}/${Date.now()}-${crypto.randomUUID()}.mp3`;
    await s3Client.send(
      new PutObjectCommand({
        Bucket: BUCKET_NAME,
        Key: audioKey,
        Body: audioBuffer,
        ContentType: "audio/mpeg",
      }),
    );

    timer.mark("s3Put");
    const audioUrl = await getSignedUrl(
      s3Client,
      new GetObjectCommand({ Bucket: BUCKET_NAME, Key: audioKey }),
      { expiresIn: AUDIO_URL_EXPIRY_SECONDS },
    );

    timer.mark("sign");

    // 5. Persist this turn (user + assistant) with a short TTL.
    const now = Date.now();
    const expiresAt = Math.floor(now / 1000) + TTL_SECONDS;
    await Promise.all([
      ddbClient.send(
        new PutCommand({
          TableName: TABLE_NAME,
          Item: { sessionId, createdAt: now, role: "user", message: text, expiresAt },
        }),
      ),
      ddbClient.send(
        new PutCommand({
          TableName: TABLE_NAME,
          Item: {
            sessionId,
            createdAt: now + 1,
            role: "assistant",
            // Store what was actually said, not English mode's JSON envelope —
            // this history is replayed straight back to Claude next turn, and
            // feeding it raw JSON would both confuse the conversation and
            // invite it to imitate the envelope in normal mode.
            message: spokenText,
            expiresAt,
          },
        }),
      ),
    ]);

    timer.mark("persist");
    timer.log({ mode: isEnglishMode ? "en" : "ja", replyChars: spokenText.length });

    return respond(200, {
      text: spokenText,
      audioUrl,
      // Present only in English-learning mode; omitted entirely otherwise so
      // the normal-mode response shape is byte-for-byte what it always was.
      ...(isEnglishMode
        ? {
            translation: extras.translation ?? null,
            hintWords: extras.hintWords ?? [],
            suggestedReplies: extras.suggestedReplies ?? [],
            testResult: extras.testResult ?? null,
          }
        : {}),
    });
  } catch (err) {
    console.error("Unhandled error", err);
    return respond(500, { error: "internal_error" });
  }
};
