import { NextResponse } from 'next/server';

import { dbConnect } from '@/lib/mongodb';
import User from '@/lib/models/User';
import Tenant from '@/lib/models/Tenant';
import { withApiError } from '@/lib/api';
import { HttpError, assertPassword, requireAdmin } from '@/lib/auth';
import { hashPassword } from '@/lib/crypto';
import { assignableRoles, listUsersData, sanitizeUser } from '@/lib/users';

export const dynamic = 'force-dynamic';

async function listUsers() {
  await dbConnect();
  const { user: actor, tenant: actorTenant } = await requireAdmin('owner');
  const data = await listUsersData(actor);
  return NextResponse.json({
    ...data,
    actorTenantId: String(actorTenant._id),
  });
}

async function createUser(request) {
  await dbConnect();
  const { user: actor } = await requireAdmin('owner');

  let body;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const username = String(body?.username || '').trim().toLowerCase();
  if (!username || !username.includes('@')) {
    return NextResponse.json(
      { error: 'A valid email address is required as the username' },
      { status: 400 }
    );
  }

  const name = String(body?.name || '').trim();
  const role = String(body?.role || 'staff');
  if (!assignableRoles(actor).includes(role)) {
    throw new HttpError(403, `You cannot create a ${role} account`);
  }

  const password = assertPassword(body?.password);

  let tenantId = actor.tenant;
  if (actor.role === 'superadmin' && body?.tenant) {
    const selector = String(body.tenant);
    const target = await Tenant.findOne({
      $or: [
        { slug: selector.toLowerCase() },
        ...(/^[0-9a-f]{24}$/i.test(selector) ? [{ _id: selector }] : []),
      ],
    });
    if (!target) throw new HttpError(400, `Tenant "${selector}" was not found`);
    tenantId = target._id;
  }

  const existing = await User.findOne({ username });
  if (existing) {
    return NextResponse.json(
      { error: `${username} already has an account` },
      { status: 409 }
    );
  }

  const created = await User.create({
    tenant: tenantId,
    username,
    name,
    role,
    passwordHash: hashPassword(password),
    active: true,
    sessionVersion: 0,
  });

  const tenant = await Tenant.findById(tenantId).lean();
  return NextResponse.json({ user: sanitizeUser(created, tenant) }, { status: 201 });
}

export const GET = withApiError(listUsers);
export const POST = withApiError(createUser);
