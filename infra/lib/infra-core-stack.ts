import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as s3 from 'aws-cdk-lib/aws-s3';

export class InfraCoreStack extends cdk.Stack {
  public readonly shortTermMemoryTable: dynamodb.Table;
  public readonly artifactsBucket: s3.Bucket;

  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // --- DynamoDB: short-term memory store (TTL-based) ---
    this.shortTermMemoryTable = new dynamodb.Table(this, 'ShortTermMemoryTable', {
      tableName: 'voice-ai-partner-short-term-memory',
      partitionKey: { name: 'sessionId', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'createdAt', type: dynamodb.AttributeType.NUMBER },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      timeToLiveAttribute: 'expiresAt',
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // --- S3: markdown artifacts / logs storage (private) ---
    this.artifactsBucket = new s3.Bucket(this, 'ArtifactsBucket', {
      bucketName: `voice-ai-partner-artifacts-${this.account}-${this.region}`,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      versioned: false,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      // Objects here are only ever reachable via short-lived presigned URLs
      // (bucket itself blocks all public access), so a permissive CORS
      // policy doesn't widen access — it just lets browser JS (the Flutter
      // web client's <audio> element / Web Audio API playback) read the
      // response. audioplayers_web sets `crossOrigin="anonymous"` on the
      // <audio> element (required for its Web Audio gain/pan nodes), which
      // makes the browser send a CORS-checked request; without a CORS
      // policy here that request fails and audio silently doesn't play.
      cors: [
        {
          allowedOrigins: ['*'],
          allowedMethods: [s3.HttpMethods.GET, s3.HttpMethods.HEAD],
          allowedHeaders: ['*'],
          exposedHeaders: ['Content-Length', 'Content-Range', 'Content-Type', 'ETag'],
          maxAge: 3000,
        },
      ],
    });

    new cdk.CfnOutput(this, 'ShortTermMemoryTableName', {
      value: this.shortTermMemoryTable.tableName,
    });

    new cdk.CfnOutput(this, 'ArtifactsBucketName', {
      value: this.artifactsBucket.bucketName,
    });
  }
}
