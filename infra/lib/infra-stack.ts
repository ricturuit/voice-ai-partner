import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as logs from 'aws-cdk-lib/aws-logs';

export interface InfraAppStackProps extends cdk.StackProps {
  shortTermMemoryTable: dynamodb.ITable;
  artifactsBucket: s3.IBucket;
}

export class InfraStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: InfraAppStackProps) {
    super(scope, id, props);

    const { shortTermMemoryTable, artifactsBucket } = props;

    // --- Secrets Manager: API key placeholders (filled in manually later) ---
    const claudeApiKeySecret = new secretsmanager.Secret(this, 'ClaudeApiKeySecret', {
      secretName: 'claude-api-key',
      description: 'Claude API key (placeholder - fill in manually)',
      secretStringValue: cdk.SecretValue.unsafePlainText('REPLACE_ME'),
    });

    const elevenLabsApiKeySecret = new secretsmanager.Secret(this, 'ElevenLabsApiKeySecret', {
      secretName: 'elevenlabs-api-key',
      description: 'ElevenLabs API key (placeholder - fill in manually)',
      secretStringValue: cdk.SecretValue.unsafePlainText('REPLACE_ME'),
    });

    // --- Secrets Manager: shared secret for API request authentication ---
    const sharedApiSecret = new secretsmanager.Secret(this, 'SharedApiSecret', {
      secretName: 'voice-ai-partner-api-shared-secret',
      description: 'Shared secret clients must send in the x-api-secret header',
      generateSecretString: {
        passwordLength: 48,
        excludePunctuation: true,
      },
    });

    // --- Lambda: health check function exposed via Function URL ---
    const healthCheckLogGroup = new logs.LogGroup(this, 'HealthCheckFunctionLogGroup', {
      logGroupName: '/aws/lambda/voice-ai-partner-health-check',
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const healthCheckFn = new lambda.Function(this, 'HealthCheckFunction', {
      functionName: 'voice-ai-partner-health-check',
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda/health-check'),
      timeout: cdk.Duration.seconds(10),
      memorySize: 128,
      logGroup: healthCheckLogGroup,
      environment: {
        SHORT_TERM_MEMORY_TABLE_NAME: shortTermMemoryTable.tableName,
        ARTIFACTS_BUCKET_NAME: artifactsBucket.bucketName,
        SHARED_API_SECRET_ARN: sharedApiSecret.secretArn,
      },
    });

    const healthCheckUrl = healthCheckFn.addFunctionUrl({
      authType: lambda.FunctionUrlAuthType.NONE,
      cors: {
        allowedOrigins: ['*'],
        allowedMethods: [lambda.HttpMethod.GET],
        allowedHeaders: ['x-api-secret'],
      },
    });

    // Grant least-privilege access for future use by the backend Lambda(s)
    shortTermMemoryTable.grantReadWriteData(healthCheckFn);
    artifactsBucket.grantReadWrite(healthCheckFn);
    sharedApiSecret.grantRead(healthCheckFn);

    new cdk.CfnOutput(this, 'HealthCheckFunctionUrl', {
      value: healthCheckUrl.url,
      description: 'Public URL for the health check Lambda Function URL',
    });

    new cdk.CfnOutput(this, 'SharedApiSecretName', {
      value: sharedApiSecret.secretName,
      description: 'Secrets Manager secret holding the shared API secret clients must send as x-api-secret',
    });

    // --- Lambda: conversation endpoint (Claude + ElevenLabs TTS) ---
    const conversationLogGroup = new logs.LogGroup(this, 'ConversationFunctionLogGroup', {
      logGroupName: '/aws/lambda/voice-ai-partner-conversation',
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // ElevenLabs preset voice ("Sarah", account-owned premade voice) used
    // until a cloned voice ID is available. Override with
    // `-c elevenLabsVoiceId=<id>` at deploy time, or by cdk.json's
    // `context.elevenLabsVoiceId` (current default), to swap it without
    // any code changes. Must be a voice already owned by the account
    // (GET /v1/voices) — the free plan rejects voice-library IDs that
    // haven't been added to the account.
    const elevenLabsVoiceId =
      (this.node.tryGetContext('elevenLabsVoiceId') as string | undefined) ??
      'EXAVITQu4vr4xnSDxMaL';

    const conversationFn = new lambda.Function(this, 'ConversationFunction', {
      functionName: 'voice-ai-partner-conversation',
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda/conversation'),
      timeout: cdk.Duration.seconds(60),
      memorySize: 256,
      logGroup: conversationLogGroup,
      environment: {
        SHORT_TERM_MEMORY_TABLE_NAME: shortTermMemoryTable.tableName,
        ARTIFACTS_BUCKET_NAME: artifactsBucket.bucketName,
        SHARED_API_SECRET_ARN: sharedApiSecret.secretArn,
        CLAUDE_API_KEY_SECRET_ARN: claudeApiKeySecret.secretArn,
        ELEVENLABS_API_KEY_SECRET_ARN: elevenLabsApiKeySecret.secretArn,
        ELEVENLABS_VOICE_ID: elevenLabsVoiceId,
        CLAUDE_MODEL: 'claude-haiku-4-5-20251001',
        ELEVENLABS_MODEL_ID: 'eleven_multilingual_v2',
      },
    });

    const conversationUrl = conversationFn.addFunctionUrl({
      authType: lambda.FunctionUrlAuthType.NONE,
      cors: {
        allowedOrigins: ['*'],
        allowedMethods: [lambda.HttpMethod.POST],
        allowedHeaders: ['x-api-secret', 'content-type'],
      },
    });

    shortTermMemoryTable.grantReadWriteData(conversationFn);
    artifactsBucket.grantReadWrite(conversationFn);
    sharedApiSecret.grantRead(conversationFn);
    claudeApiKeySecret.grantRead(conversationFn);
    elevenLabsApiKeySecret.grantRead(conversationFn);

    new cdk.CfnOutput(this, 'ConversationFunctionUrl', {
      value: conversationUrl.url,
      description: 'POST endpoint for the conversation Lambda (Claude + ElevenLabs TTS)',
    });
  }
}
