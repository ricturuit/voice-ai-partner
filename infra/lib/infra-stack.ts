import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';

export interface InfraAppStackProps extends cdk.StackProps {
  shortTermMemoryTable: dynamodb.ITable;
  artifactsBucket: s3.IBucket;
}

export class InfraStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: InfraAppStackProps) {
    super(scope, id, props);

    const { shortTermMemoryTable, artifactsBucket } = props;

    // --- Secrets Manager: API key placeholders (filled in manually later) ---
    new secretsmanager.Secret(this, 'ClaudeApiKeySecret', {
      secretName: 'claude-api-key',
      description: 'Claude API key (placeholder - fill in manually)',
      secretStringValue: cdk.SecretValue.unsafePlainText('REPLACE_ME'),
    });

    new secretsmanager.Secret(this, 'ElevenLabsApiKeySecret', {
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
    const healthCheckFn = new lambda.Function(this, 'HealthCheckFunction', {
      functionName: 'voice-ai-partner-health-check',
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda/health-check'),
      timeout: cdk.Duration.seconds(10),
      memorySize: 128,
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
  }
}
