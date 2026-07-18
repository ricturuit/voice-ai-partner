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
const ELEVENLABS_MODEL_ID = process.env.ELEVENLABS_MODEL_ID || "eleven_multilingual_v2";
// Keeps replies short by construction — both to fit the character's
// "necessary minimum per turn" conversational style (see system-prompt.md)
// and to bound Claude output tokens + ElevenLabs TTS characters (both
// billed per unit), rather than relying on the prompt alone to self-limit.
const CLAUDE_MAX_TOKENS = parseInt(process.env.CLAUDE_MAX_TOKENS || "220", 10);
// Character persona/style instructions, edited as a standalone file rather
// than an env var (Lambda env vars share a 4KB total budget across all of
// them, too tight for a prompt this size) — edit system-prompt.md and
// redeploy to change how the character speaks.
const SYSTEM_PROMPT = fs.readFileSync(path.join(__dirname, "system-prompt.md"), "utf8");
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

exports.handler = async (event) => {
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

    const claudeMessages = history.map((item) => ({
      role: item.role,
      content: item.message,
    }));
    claudeMessages.push({ role: "user", content: text });

    // 2. Ask Claude for a reply, with history as context.
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
        system: SYSTEM_PROMPT,
        messages: claudeMessages,
      }),
    });

    if (!claudeResponse.ok) {
      console.error("Claude API error", claudeResponse.status, await claudeResponse.text());
      return respond(502, { error: "claude_api_error" });
    }

    const claudeData = await claudeResponse.json();
    const replyText = (claudeData.content || [])
      .filter((block) => block.type === "text")
      .map((block) => block.text)
      .join("\n")
      .trim();

    if (!replyText) {
      console.error("Claude API returned no text content", JSON.stringify(claudeData));
      return respond(502, { error: "empty_claude_response" });
    }

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
          text: replyText,
          model_id: ELEVENLABS_MODEL_ID,
        }),
      },
    );

    if (!ttsResponse.ok) {
      console.error("ElevenLabs API error", ttsResponse.status, await ttsResponse.text());
      return respond(502, { error: "tts_api_error" });
    }

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

    const audioUrl = await getSignedUrl(
      s3Client,
      new GetObjectCommand({ Bucket: BUCKET_NAME, Key: audioKey }),
      { expiresIn: AUDIO_URL_EXPIRY_SECONDS },
    );

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
            message: replyText,
            expiresAt,
          },
        }),
      ),
    ]);

    return respond(200, { text: replyText, audioUrl });
  } catch (err) {
    console.error("Unhandled error", err);
    return respond(500, { error: "internal_error" });
  }
};
