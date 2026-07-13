const {
  SecretsManagerClient,
  GetSecretValueCommand,
} = require("@aws-sdk/client-secrets-manager");

const secretsClient = new SecretsManagerClient({});

// Cached across warm invocations so we don't call Secrets Manager on every request.
let cachedSecretValue;

async function getSharedSecret() {
  if (cachedSecretValue) {
    return cachedSecretValue;
  }
  const response = await secretsClient.send(
    new GetSecretValueCommand({ SecretId: process.env.SHARED_API_SECRET_ARN }),
  );
  cachedSecretValue = response.SecretString;
  return cachedSecretValue;
}

exports.handler = async (event) => {
  const providedSecret = (event.headers && event.headers["x-api-secret"]) || "";
  const expectedSecret = await getSharedSecret();

  if (providedSecret !== expectedSecret) {
    return {
      statusCode: 401,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ error: "unauthorized" }),
    };
  }

  return {
    statusCode: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      status: "ok",
      service: "voice-ai-partner-backend",
      phase: "phase1",
      timestamp: new Date().toISOString(),
    }),
  };
};
