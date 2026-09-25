import {
  createHash,
  createHmac,
  randomBytes,
  scryptSync,
  timingSafeEqual,
} from 'node:crypto';

/// Password hashing, API keys and signed session tokens.
///
/// Kept free of Next.js imports so maintenance scripts (seed, import,
/// create-tenant) can use the same primitives.

const KEY_LENGTH = 64;
const SESSION_DAYS = 7;

export function getAuthSecret() {
  const secret = process.env.AUTH_SECRET;
  if (!secret || secret.length < 16) {
    throw new Error(
      'AUTH_SECRET is not set (or too short). Add a long random value to .env.local.'
    );
  }
  return secret;
}

export function hashPassword(password) {
  const salt = randomBytes(16).toString('hex');
  const hash = scryptSync(String(password), salt, KEY_LENGTH).toString('hex');
  return `scrypt$${salt}$${hash}`;
}

export function verifyPassword(password, stored) {
  const [scheme, salt, hash] = String(stored || '').split('$');
  if (scheme !== 'scrypt' || !salt || !hash) return false;
  const expected = Buffer.from(hash, 'hex');
  const computed = scryptSync(String(password), salt, KEY_LENGTH);
  if (computed.length !== expected.length) return false;
  return timingSafeEqual(computed, expected);
}

/// Long, URL-safe key the POS Hub uses to pull a tenant's menu.
export function randomApiKey() {
  return randomBytes(24).toString('base64url');
}

export function base64url(value) {
  return Buffer.from(value).toString('base64url');
}

export function createSessionToken({ userId, tenantId, sessionVersion = 0 }) {
  const payload = base64url(
    JSON.stringify({
      uid: String(userId),
      tid: String(tenantId),
      sv: Number(sessionVersion) || 0,
      exp: Date.now() + SESSION_DAYS * 24 * 60 * 60 * 1000,
    })
  );
  const signature = createHmac('sha256', getAuthSecret())
    .update(payload)
    .digest('base64url');
  return `${payload}.${signature}`;
}

export function readSessionToken(token) {
  const [payload, signature] = String(token || '').split('.');
  if (!payload || !signature) return null;

  const expected = createHmac('sha256', getAuthSecret())
    .update(payload)
    .digest('base64url');
  if (signature.length !== expected.length) return null;
  if (!timingSafeEqual(Buffer.from(signature), Buffer.from(expected))) return null;

  try {
    const data = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    if (!data?.uid || !data?.tid || !data?.exp) return null;
    if (Date.now() > data.exp) return null;
    return {
      userId: data.uid,
      tenantId: data.tid,
      sessionVersion: Number(data.sv) || 0,
    };
  } catch {
    return null;
  }
}

/// High-entropy token for password-reset links.
export function randomToken() {
  return randomBytes(32).toString('base64url');
}

/// Reset tokens are random, so a fast one-way hash is enough. Only the hash is
/// stored, so a database leak does not expose usable links.
export function hashToken(token) {
  return createHash('sha256').update(String(token)).digest('hex');
}

export function tokensMatch(rawToken, storedHash) {
  const computed = hashToken(rawToken);
  const expected = String(storedHash || '');
  if (computed.length !== expected.length) return false;
  return timingSafeEqual(Buffer.from(computed), Buffer.from(expected));
}

export const SESSION_COOKIE = 'portal_session';
export const SESSION_MAX_AGE_SECONDS = SESSION_DAYS * 24 * 60 * 60;

export function sessionCookieOptions() {
  return {
    httpOnly: true,
    sameSite: 'lax',
    path: '/',
    maxAge: SESSION_MAX_AGE_SECONDS,
    // The portal is normally reached over plain HTTP on the LAN
    // (http://<mac>:3000), where a Secure cookie is silently dropped. Set
    // AUTH_COOKIE_SECURE=1 when serving it behind TLS.
    secure: process.env.AUTH_COOKIE_SECURE === '1',
  };
}
