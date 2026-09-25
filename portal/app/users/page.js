import UserManager from '@/components/UserManager';
import { requireAdmin } from '@/lib/auth';
import { listUsersData } from '@/lib/users';

export const dynamic = 'force-dynamic';

export default async function UsersPage() {
  let initial = null;

  try {
    const { user: actor } = await requireAdmin('owner');
    initial = await listUsersData(actor);
  } catch {
    initial = null;
  }

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Users</h1>
          <p>
            Add accounts for your restaurant and manage roles, passwords and
            access. Superadmins can manage every restaurant.
          </p>
        </div>
      </div>

      {initial ? (
        <UserManager initial={initial} />
      ) : (
        <div className="notice notice-error">
          You need an owner or superadmin account to manage users.
        </div>
      )}
    </>
  );
}
