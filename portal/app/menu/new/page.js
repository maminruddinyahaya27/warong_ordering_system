import Link from 'next/link';
import { dbConnect } from '@/lib/mongodb';
import Station from '@/lib/models/Station';
import MenuItem from '@/lib/models/MenuItem';
import MenuGroup from '@/lib/models/MenuGroup';
import { ensureGroups, getSettings, serializeGroup } from '@/lib/menu-service';
import MenuItemForm from '@/components/MenuItemForm';
import ConfigError from '@/components/ConfigError';
import { requireTenant } from '@/lib/auth';

export const dynamic = 'force-dynamic';

async function loadFormData() {
  await dbConnect();
  const tenant = await requireTenant();
  await ensureGroups(tenant);

  const [stationDocs, menuStations, settings, groupDocs] = await Promise.all([
    Station.find({ tenant: tenant._id }).sort({ sortOrder: 1, name: 1 }).lean(),
    MenuItem.distinct('station', { tenant: tenant._id }),
    getSettings(tenant),
    MenuGroup.find({ tenant: tenant._id }).sort({ sortOrder: 1, name: 1 }).lean(),
  ]);

  const names = [
    ...new Set([
      ...stationDocs.map((station) => station.name),
      ...menuStations.filter(Boolean),
    ]),
  ].sort((a, b) => a.localeCompare(b));

  return {
    names,
    currency: settings.currency || 'RM',
    groups: groupDocs.map((group) => serializeGroup(group)),
  };
}

export default async function NewMenuItemPage({ searchParams }) {
  const resolved = (await searchParams) || {};
  const defaultGroupId =
    typeof resolved.group === 'string' ? resolved.group : '';
  // Where to return after saving: the menu list with its filters intact.
  const returnTo =
    typeof resolved.from === 'string' && resolved.from.startsWith('/menu')
      ? resolved.from
      : '/menu';

  let data = null;
  let error = null;
  try {
    data = await loadFormData();
  } catch (loadError) {
    error = loadError;
  }

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Add menu item</h1>
          <p>Create a new dish or drink and put it in a group.</p>
        </div>
        <span className="spacer" />
        <Link className="btn" href="/menu">
          Back to menu
        </Link>
      </div>

      {error ? (
        <ConfigError error={error} />
      ) : (
        <MenuItemForm
          stations={data.names}
          groups={data.groups}
          defaultGroupId={defaultGroupId}
          currency={data.currency}
          returnTo={returnTo}
        />
      )}
    </>
  );
}
