import mongoose from 'mongoose';
import { cookies } from 'next/headers';

import { dbConnect } from '@/lib/mongodb';
import Tenant from '@/lib/models/Tenant';
import User from '@/lib/models/User';
import {
  SESSION_COOKIE,
  createSessionToken,
  hashPassword,
  hashToken,
  randomToken,
  readSessionToken,
  sessionCookieOptions,
  tokensMatch,
  verifyPassword,
} from '@/lib/crypto';

export const MIN_PASSWORD_LENGTH = 8;

export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export function assertPassword(password) {
  const value = String(password || '');
  if (value.length < MIN_PASSWORD_LENGTH) {
    throw new HttpError(
      400,
      `Password must be at least ${MIN_PASSWORD_LENGTH} characters`
    );
  }
  return value;
}

/// Validates a username/password pair and returns the user with its tenant.
export async function authenticate(username, password) {
  await dbConnect();
  const user = await User.findOne({
    username: String(username || '').trim().toLowerCase(),
  });
  if (!user) return null;
  if (user.active === false) return null;
  if (!verifyPassword(password, user.passwordHash)) return null;

  const tenant = await Tenant.findById(user.tenant);
  if (!tenant || tenant.active === false) return null;

  user.lastLoginAt = new Date();
  await user.save();
  return { user, tenant };
}

export async function startSession(user) {
  const token = createSessionToken({
    userId: user.id ?? user._id,
    tenantId: user.tenant,
    sessionVersion: user.sessionVersion ?? 0,
  });
  const store = await cookies();
  store.set(SESSION_COOKIE, token, sessionCookieOptions());
  return token;
}

export async function endSession() {
  const store = await cookies();
  store.delete(SESSION_COOKIE);
}

/// The signed-in session, or null. Signature + expiry only — the ids inside
/// are trusted because the token is HMAC-signed.
export async function getSession() {
  const store = await cookies();
  return readSessionToken(store.get(SESSION_COOKIE)?.value);
}

/// For API routes: the session, or a 401. Re-checks the user in the database so
/// deactivating an account or changing its password invalidates old sessions.
/// `tenantId` is returned as an ObjectId so it also works inside aggregation
/// pipelines, which Mongoose does not cast for us.
export async function requireSession() {
  const session = await getSession();
  if (!session) throw new HttpError(401, 'Authentication required');

  await dbConnect();
  const user = await User.findById(session.userId);
  if (!user || user.active === false) {
    throw new HttpError(401, 'Session is no longer valid');
  }
  if ((user.sessionVersion ?? 0) !== (session.sessionVersion ?? 0)) {
    throw new HttpError(401, 'Session is no longer valid');
  }

  return {
    userId: String(user._id),
    tenantId: mongoose.isValidObjectId(user.tenant)
      ? new mongoose.Types.ObjectId(user.tenant)
      : user.tenant,
    sessionVersion: user.sessionVersion ?? 0,
    role: user.role,
    user,
  };
}

/// The signed-in user with its tenant, for pages that show the account name.
export async function requireUser() {
  const session = await requireSession();
  const tenant = await Tenant.findById(session.tenantId).lean();
  if (!tenant) throw new HttpError(401, 'Session is no longer valid');
  return { session, user: session.user, tenant };
}

/// For server components: the signed-in tenant, or a 401.
export async function requireTenant() {
  const session = await requireSession();
  const tenant = await Tenant.findById(session.tenantId).lean();
  if (!tenant) throw new HttpError(401, 'Session is no longer valid');
  return tenant;
}

const ROLE_RANK = { staff: 1, owner: 2, superadmin: 3 };

/// True when `role` is at least `minimum` (staff < owner < superadmin).
export function roleAtLeast(role, minimum) {
  return (ROLE_RANK[role] || 0) >= (ROLE_RANK[minimum] || 0);
}

/// For admin-only API routes: the signed-in user, or a 403 when its role is
/// below `minimum`.
export async function requireAdmin(minimum = 'owner') {
  const { session, user, tenant } = await requireUser();
  if (!roleAtLeast(user.role, minimum)) {
    throw new HttpError(403, 'You do not have permission to manage users');
  }
  return { session, user, tenant };
}

/// Creates a password-reset token for a user, stores its hash, and returns the
/// raw token to put in the reset email.
export async function createPasswordReset(user, ttlMinutes = 60) {
  const raw = randomToken();
  user.resetTokenHash = hashToken(raw);
  user.resetTokenExpiresAt = new Date(Date.now() + ttlMinutes * 60 * 1000);
  await user.save();
  return raw;
}

/// Finds the active user a reset token belongs to, or null.
export async function findUserByResetToken(rawToken) {
  if (!rawToken) return null;
  await dbConnect();
  const user = await User.findOne({ resetTokenHash: hashToken(String(rawToken)) });
  if (!user || !user.resetTokenHash) return null;
  if (user.active === false) return null;
  if (!user.resetTokenExpiresAt || user.resetTokenExpiresAt.getTime() < Date.now()) {
    return null;
  }
  if (!tokensMatch(rawToken, user.resetTokenHash)) return null;
  return user;
}

/// Sets a new password, ends every existing session for the user, and clears
/// any pending reset token.
export async function setUserPassword(user, newPassword) {
  assertPassword(newPassword);
  user.passwordHash = hashPassword(newPassword);
  user.sessionVersion = (user.sessionVersion ?? 0) + 1;
  user.resetTokenHash = null;
  user.resetTokenExpiresAt = null;
  await user.save();
  return user;
}

/// Resolves the tenant for a menu feed request:
///   1. `X-Api-Key` header
///   2. Basic auth — username is the tenant API key, or a portal login
///   3. `?key=` query parameter (used by the browser mockups)
///   4. the session cookie
export async function tenantForRequest(request) {
  await dbConnect();

  const headerKey = (request.headers.get('x-api-key') || '').trim();
  if (headerKey) {
    const tenant = await Tenant.findOne({ apiKey: headerKey });
    if (tenant) return tenant;
  }

  const authorization = request.headers.get('authorization') || '';
  if (authorization.startsWith('Basic ')) {
    let decoded = '';
    try {
      decoded = Buffer.from(authorization.slice(6), 'base64').toString('utf8');
    } catch {
      decoded = '';
    }
    const separator = decoded.indexOf(':');
    if (separator !== -1) {
      const user = decoded.slice(0, separator);
      const pass = decoded.slice(separator + 1);
      const byKey = await Tenant.findOne({ apiKey: user });
      if (byKey) return byKey;
      const found = await authenticate(user, pass);
      if (found) return found.tenant;
    }
  }

  try {
    const queryKey = (new URL(request.url).searchParams.get('key') || '').trim();
    if (queryKey) {
      const tenant = await Tenant.findOne({ apiKey: queryKey });
      if (tenant) return tenant;
    }
  } catch {
    // ignore malformed URLs
  }

  const session = await getSession();
  if (session) {
    return Tenant.findById(session.tenantId);
  }
  return null;
}
