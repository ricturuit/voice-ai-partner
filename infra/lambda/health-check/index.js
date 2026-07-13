exports.handler = async () => {
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
