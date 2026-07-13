import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import * as s3 from 'aws-cdk-lib/aws-s3';

export class InfraWebStack extends cdk.Stack {
  public readonly websiteBucket: s3.Bucket;

  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // Static hosting for the Flutter web client. Public read-only, no
    // secrets or user data ever live here — the API shared secret is baked
    // into the built JS bundle at build time (see app/README.md).
    this.websiteBucket = new s3.Bucket(this, 'WebsiteBucket', {
      bucketName: `voice-ai-partner-web-${this.account}-${this.region}`,
      websiteIndexDocument: 'index.html',
      websiteErrorDocument: 'index.html',
      publicReadAccess: true,
      blockPublicAccess: new s3.BlockPublicAccess({
        blockPublicAcls: true,
        ignorePublicAcls: true,
        blockPublicPolicy: false,
        restrictPublicBuckets: false,
      }),
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    new cdk.CfnOutput(this, 'WebsiteUrl', {
      value: this.websiteBucket.bucketWebsiteUrl,
      description: 'Public URL for the Flutter web client (S3 static website hosting)',
    });
  }
}
