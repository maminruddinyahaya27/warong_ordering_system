import { HttpError } from '@/lib/auth';
import User from '@/lib/models/User';
import Tenant from '@/lib/models/Tenant';

/// Roles `actor` may assign. Owners cannot create or grant superadmin.
export function assignableRoles(actor) {
  return actor.role === 'superadmin'
    ? ['superadmin', 'owner', 'staff']
    : ['owner', 'staff'];
}

/// The shape the users API and UI use (never includes the password hash).
export function sanitizeUser(user, tenant) {
  return {
    id: String(user._id),
    username: user.username,
    name: user.name || '',
    role: user.role,
    active: user.active !== false,
    tenant: tenant
      ? { id: String(tenant._id), name: tenant.name, slug: tenant.slug }
      : { id: String(user.tenant), name: '', slug: '' },
    lastLoginAt: user.lastLoginAt
      ? new Date(user.lastLoginAt).toISOString()
      : null,
    createdAt: user.createdAt ? new Date(user.createdAt).toISOString() : null,
  };
}

/// True when `actor` may edit `target` (row-level tenant/role rules).
export function canManageUser(actor, target) {
  if (actor.role === 'superadmin') return true;
  if (String(actor.tenant) !== String(target.tenant)) return false;
  return target.role !== 'superadmin';
}

/// Validates an actor attempting to CHANGE a user to `nextRole`.
export function assertRoleAssignable(actor, nextRole) {
  if (!assignableRoles(actor).includes(nextRole)) {
    throw new HttpError(403, `You cannot grant the ${nextRole} role`);
  }
}

/// The user list the API and the Users page both render. Superadmins see every
/// account and the tenant list; owners see only their own restaurant.
export async function listUsersData(actor) {
  const scope = actor.role === 'superadmin' ? {} : { tenant: actor.tenant };
  const users = await User.find(scope).sort({ createdAt: 1 }).lean();

  const tenantIds = [...new Set(users.map((u) => String(u.tenant)))];
  const tenants = await Tenant.find({ _id: { $in: tenantIds } }).lean();
  const tenantById = new Map(tenants.map((t) => [String(t._id), t]));

  let allTenants = [];
  if (actor.role === 'superadmin') {
    const docs = await Tenant.find({}).sort({ name: 1 }).lean();
    allTenants = docs.map((t) => ({ id: String(t._id), name: t.name, slug: t.slug }));
  }

  return {
    users: users.map((u) => sanitizeUser(u, tenantById.get(String(u.tenant)))),
    tenants: allTenants,
    canManageAllTenants: actor.role === 'superadmin',
    currentUserId: String(actor._id),
  };
}
