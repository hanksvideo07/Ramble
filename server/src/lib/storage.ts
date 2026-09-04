import {
  CreateBucketCommand,
  GetObjectCommand,
  HeadBucketCommand,
  PutObjectCommand,
  S3Client,
} from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { config } from './config.ts';
import { log } from './logger.ts';

/**
 * Audio lives in private object storage. Nothing is ever public: the app
 * receives a short-lived signed URL scoped to one object.
 */
const client = new S3Client({
  endpoint: config.s3.endpoint,
  region: config.s3.region,
  forcePathStyle: config.s3.forcePathStyle,
  credentials: {
    accessKeyId: config.s3.accessKeyId,
    secretAccessKey: config.s3.secretAccessKey,
  },
});

export async function ensureBucket(): Promise<void> {
  try {
    await client.send(new HeadBucketCommand({ Bucket: config.s3.bucket }));
  } catch {
    await client.send(new CreateBucketCommand({ Bucket: config.s3.bucket }));
    log.info('storage.bucket_created', { bucket: config.s3.bucket });
  }
}

/** Keys are namespaced per user so a signed URL can never span users. */
export function audioKey(userId: string, rambleId: string, extension = 'm4a'): string {
  return `users/${userId}/rambles/${rambleId}.${extension}`;
}

export async function putAudio(
  key: string,
  body: Buffer,
  contentType: string,
): Promise<void> {
  await client.send(
    new PutObjectCommand({
      Bucket: config.s3.bucket,
      Key: key,
      Body: body,
      ContentType: contentType,
    }),
  );
}

export async function getAudio(key: string): Promise<Buffer> {
  const response = await client.send(
    new GetObjectCommand({ Bucket: config.s3.bucket, Key: key }),
  );
  const bytes = await response.Body?.transformToByteArray();
  if (!bytes) throw new Error(`No audio body at key ${key}.`);
  return Buffer.from(bytes);
}

export async function signedPlaybackUrl(key: string): Promise<string> {
  return getSignedUrl(client, new GetObjectCommand({ Bucket: config.s3.bucket, Key: key }), {
    expiresIn: config.s3.signedUrlTtl,
  });
}
