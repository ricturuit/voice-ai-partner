import * as cdk from 'aws-cdk-lib/core';
import { Construct } from 'constructs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';

export class InfraWebStack extends cdk.Stack {
  public readonly websiteBucket: s3.Bucket;
  public readonly distribution: cloudfront.Distribution;

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

    // CloudFront in front of the S3 website endpoint, purely to get HTTPS
    // (the browser's Web Speech API / getUserMedia require a secure
    // context, which the S3 website endpoint alone can't provide — it's
    // HTTP only). Uses CloudFront's default *.cloudfront.net certificate,
    // so no ACM cert / custom domain needed. This is expected to be
    // throwaway infrastructure for the verification phase before this
    // becomes a native mobile app, so it's kept as cheap/simple as
    // possible (no custom domain, no WAF, PriceClass_100 to limit edge
    // locations used).
    this.distribution = new cloudfront.Distribution(this, 'WebsiteDistribution', {
      defaultBehavior: {
        origin: new origins.HttpOrigin(this.websiteBucket.bucketWebsiteDomainName, {
          protocolPolicy: cloudfront.OriginProtocolPolicy.HTTP_ONLY,
        }),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        allowedMethods: cloudfront.AllowedMethods.ALLOW_GET_HEAD,
        cachedMethods: cloudfront.CachedMethods.CACHE_GET_HEAD,
      },
      defaultRootObject: 'index.html',
      priceClass: cloudfront.PriceClass.PRICE_CLASS_100,
    });

    new cdk.CfnOutput(this, 'WebsiteUrl', {
      value: this.websiteBucket.bucketWebsiteUrl,
      description: 'Public URL for the Flutter web client (S3 static website hosting, HTTP only)',
    });

    new cdk.CfnOutput(this, 'WebsiteHttpsUrl', {
      value: `https://${this.distribution.distributionDomainName}`,
      description:
        'HTTPS URL via CloudFront — use this one; required for mic access (secure context)',
    });
  }
}
