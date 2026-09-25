import { NextResponse } from 'next/server';

import { dbConnect } from '@/lib/mongodb';
import User from '@/lib/models/User';
import Tenant from '@/lib/models/Tenant';
import { withApiError } from '@/lib/api';
import { HttpError, requireAdmin, setUserPassword, startSession } from '@/lib/auth';
import { assertRoleAssignable, canManageUser, sanitizeUser } from '@/lib/users';

export const dynamic = 'force-dynamic';

async function findTarget(id) {
  if (!id || !/^[0-9a-f]{24}$/i.test(String(id))) {
    throw new HttpError(404, 'User not found');
  }
  const target = await User.findById(id);
  if (!target) throw new HttpError(404, 'User not found');
  return target;
}

async function activeSuperadminCount() {
  return User.countDocuments({ role: 'superadmin', active: true });
}

async function updateUser(request, { params }) {
  await dbConnect();
  const { user: actor } = await requireAdmin('owner');
  const { id } = await params;
  const target = await findTarget(id);

  if (!canManageUser(actor, target)) {
    throw new HttpError(403, 'You cannot manage this user');
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const isSelf = String(actor._id) === String(target._id);
  const wantsRole = body?.role !== undefined && body.role !== target.role;
  // Normalize `active` once so non-boolean values (0, "false") cannot slip past
  // the guard below while still deactivating the account.
  const hasActive = body?.active !== undefined;
  const nextActive = hasActive ? Boolean(body.active) : target.active !== false;
  const wantsDeactivate = hasActive && nextActive === false;

  if (isSelf && wantsRole) {
    throw new HttpError(400, 'You cannot change your own role');
  }
  if (isSelf && wantsDeactivate) {
    throw new HttpError(400, 'You cannot deactivate your own account');
  }

  if (wantsRole) {
    assertRoleAssignable(actor, String(body.role));
  }

  // Never leave the portal without an active superadmin.
  if (
    target.role === 'superadmin' &&
    (wantsRole || wantsDeactivate)
  ) {
    const remaining = await activeSuperadminCount();
    if (remaining <= 1) {
      throw new HttpError(
        400,
        'This is the last active superadmin; promote another one first'
      );
    }
  }

  if (body?.name !== undefined) target.name = String(body.name).trim();
  if (body?.role !== undefined) target.role = String(body.role);

  let passwordChanged = false;
  if (body?.password) {
    await setUserPassword(target, body.password);
    passwordChanged = true;
  }

  if (hasActive && nextActive !== (target.active !== false)) {
    target.active = nextActive;
    // Bump the version so any existing session is rejected immediately.
    target.sessionVersion = (target.sessionVersion ?? 0) + 1;
    if (nextActive === false) {
      target.resetTokenHash = null;
      target.resetTokenExpiresAt = null;
    }
  }

  await target.save();

  // A self password change bumps sessionVersion; refresh this session so the
  // admin is not logged out of the request they just made.
  if (isSelf && passwordChanged) {
    await startSession(target);
  }

  const tenant = await Tenant.findById(target.tenant).lean();
  return NextResponse.json({ user: sanitizeUser(target, tenant) });
}

async function deleteUser(_request, { params }) {
  await dbConnect();
  const { user: actor } = await requireAdmin('owner');
  const { id } = await params;
  const target = await findTarget(id);

  if (String(actor._id) === String(target._id)) {
    throw new HttpError(400, 'You cannot delete your own account');
  }
  if (!canManageUser(actor, target)) {
    throw new HttpError(403, 'You cannot manage this user');
  }
  if (target.role === 'superadmin' && (await activeSuperadminCount()) <= 1) {
    throw new HttpError(
      400,
      'This is the last active superadmin; promote another one first'
    );
  }

  await target.deleteOne();
  return NextResponse.json({ ok: true, id: String(target._id) });
}

export const PATCH = withApiError(updateUser);
export const DELETE = withApiError(deleteUser);
