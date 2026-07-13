import * as fs from 'fs';
import * as path from 'path';
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

    // --- Lambda: health check function exposed via Function URL ---
    // Inline code (no S3 asset upload) so this doesn't depend on a CDK
    // bootstrap staging bucket.
    const healthCheckSource = fs.readFileSync(
      path.join(__dirname, '..', 'lambda', 'health-check', 'index.js'),
      'utf8',
    );

    const healthCheckFn = new lambda.Function(this, 'HealthCheckFunction', {
      functionName: 'voice-ai-partner-health-check',
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      code: lambda.Code.fromInline(healthCheckSource),
      timeout: cdk.Duration.seconds(10),
      memorySize: 128,
      environment: {
        SHORT_TERM_MEMORY_TABLE_NAME: shortTermMemoryTable.tableName,
        ARTIFACTS_BUCKET_NAME: artifactsBucket.bucketName,
      },
    });

    const healthCheckUrl = healthCheckFn.addFunctionUrl({
      authType: lambda.FunctionUrlAuthType.NONE,
      cors: {
        allowedOrigins: ['*'],
        allowedMethods: [lambda.HttpMethod.GET],
      },
    });

    // Grant least-privilege access for future use by the backend Lambda(s)
    shortTermMemoryTable.grantReadWriteData(healthCheckFn);
    artifactsBucket.grantReadWrite(healthCheckFn);

    new cdk.CfnOutput(this, 'HealthCheckFunctionUrl', {
      value: healthCheckUrl.url,
      description: 'Public URL for the health check Lambda Function URL',
    });
  }
}
