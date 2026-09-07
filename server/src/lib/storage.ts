import { createHmac, timingSafeEqual } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, normalize, resolve } from 'node:path';
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
 * Audio storage.
 *
 * Two backends behind one interface: S3-compatible object storage where it is
 * available, and a plain directory (backed by a persistent volume) where it is
 * not. Either way nothing is public — playback goes through a short-lived
 * signed URL scoped to one object.
 */
export interface StorageAdapter {
  readonly name: string;
  ensureReady(): Promise<void>;
  put(key: string, body: Buffer, contentType: string): Promise<void>;
  get(key: string): Promise<Buffer>;
  signedUrl(key: string): Promise<string>;
}

// --- S3 --------------------------------------------------------------------

class S3Storage implements StorageAdapter {
  readonly name = 's3';
  private readonly client: S3Client;

  constructor() {
    this.client = new S3Client({
      endpoint: config.s3.endpoint,
      region: config.s3.region,
      forcePathStyle: config.s3.forcePathStyle,
      credentials: {
        accessKeyId: config.s3.accessKeyId,
        secretAccessKey: config.s3.secretAccessKey,
      },
    });
  }

  async ensureReady(): Promise<void> {
    try {
      await this.client.send(new HeadBucketCommand({ Bucket: config.s3.bucket }));
    } catch {
      await this.client.send(new CreateBucketCommand({ Bucket: config.s3.bucket }));
      log.info('storage.bucket_created', { bucket: config.s3.bucket });
    }
  }

  async put(key: string, body: Buffer, contentType: string): Promise<void> {
    await this.client.send(
      new PutObjectCommand({ Bucket: config.s3.bucket, Key: key, Body: body, ContentType: contentType }),
    );
  }

  async get(key: string): Promise<Buffer> {
    const response = await this.client.send(
      new GetObjectCommand({ Bucket: config.s3.bucket, Key: key }),
    );
    const bytes = await response.Body?.transformToByteArray();
    if (!bytes) throw new Error(`No audio body at key ${key}.`);
    return Buffer.from(bytes);
  }

  async signedUrl(key: string): Promise<string> {
    return getSignedUrl(this.client, new GetObjectCommand({ Bucket: config.s3.bucket, Key: key }), {
      expiresIn: config.s3.signedUrlTtl,
    });
  }
}

// --- Filesystem ------------------------------------------------------------

/**
 * Stores audio on a persistent volume.
 *
 * There is no object store to presign against, so playback URLs are signed
 * here with an HMAC over the key and an expiry, and served back by
 * `GET /v1/audio`. AVPlayer cannot attach an Authorization header to a media
 * request, which is exactly why the capability has to live in the URL.
 */
class FilesystemStorage implements StorageAdapter {
  readonly name = 'filesystem';

  constructor(private readonly root: string) {}

  async ensureReady(): Promise<void> {
    await mkdir(this.root, { recursive: true });
    log.info('storage.filesystem_ready', { root: this.root });
  }

  /** Resolves a key inside the root, refusing anything that escapes it. */
  private pathFor(key: string): string {
    const full = resolve(join(this.root, normalize(key)));
    if (full !== this.root && !full.startsWith(this.root + '/')) {
      throw new Error('Refusing to access a path outside the storage root.');
    }
    return full;
  }

  async put(key: string, body: Buffer, _contentType: string): Promise<void> {
    const path = this.pathFor(key);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, body);
  }

  async get(key: string): Promise<Buffer> {
    return readFile(this.pathFor(key));
  }

  async signedUrl(key: string): Promise<string> {
    const expires = Math.floor(Date.now() / 1000) + config.s3.signedUrlTtl;
    const signature = signKey(key, expires);
    const params = new URLSearchParams({ key, expires: String(expires), sig: signature });
    return `${config.publicUrl}/v1/audio?${params}`;
  }
}

/** HMAC over the object key and its expiry. */
export function signKey(key: string, expires: number): string {
  return createHmac('sha256', config.authSecret).update(`${key}:${expires}`).digest('hex');
}

/** Constant-time check that a playback URL is genuine and still valid. */
export function verifyKeySignature(key: string, expires: number, signature: string): boolean {
  if (!Number.isFinite(expires) || expires < Math.floor(Date.now() / 1000)) return false;
  const expected = Buffer.from(signKey(key, expires), 'utf8');
  const provided = Buffer.from(signature, 'utf8');
  return expected.length === provided.length && timingSafeEqual(expected, provided);
}

// --- selection -------------------------------------------------------------

function createStorage(): StorageAdapter {
  // A volume mount wins when present: it is the deployment that has no object
  // store, and falling back to S3 there would silently lose recordings.
  if (config.storage.directory) return new FilesystemStorage(resolve(config.storage.directory));
  return new S3Storage();
}

export const storage: StorageAdapter = createStorage();

export async function ensureBucket(): Promise<void> {
  await storage.ensureReady();
}

/** Keys are namespaced per user so a signed URL can never span users. */
export function audioKey(userId: string, rambleId: string, extension = 'm4a'): string {
  return `users/${userId}/rambles/${rambleId}.${extension}`;
}

export async function putAudio(key: string, body: Buffer, contentType: string): Promise<void> {
  await storage.put(key, body, contentType);
}

export async function getAudio(key: string): Promise<Buffer> {
  return storage.get(key);
}

export async function signedPlaybackUrl(key: string): Promise<string> {
  return storage.signedUrl(key);
}
