import { dbConnect } from '@/lib/mongodb';
import MenuGroup from '@/lib/models/MenuGroup';
import MenuItem from '@/lib/models/MenuItem';
import Station from '@/lib/models/Station';
import { ensureGroups, serializeGroup } from '@/lib/menu-service';
import GroupManager from '@/components/GroupManager';
import ConfigError from '@/components/ConfigError';
import { requireTenant } from '@/lib/auth';

export const dynamic = 'force-dynamic';

async function loadGroups() {
  await dbConnect();
  const tenant = await requireTenant();
  await ensureGroups(tenant);

  const [groups, counts, ungroupedCount, stations] = await Promise.all([
    MenuGroup.find({ tenant: tenant._id }).sort({ sortOrder: 1, name: 1 }).lean(),
    MenuItem.aggregate([
      { $match: { tenant: tenant._id, group: { $ne: null } } },
      { $group: { _id: '$group', count: { $sum: 1 } } },
    ]),
    MenuItem.countDocuments({ tenant: tenant._id, group: null }),
    Station.find({ tenant: tenant._id }).sort({ sortOrder: 1, name: 1 }).lean(),
  ]);

  const countMap = new Map(counts.map((row) => [String(row._id), row.count]));

  return {
    groups: groups.map((group) =>
      serializeGroup(group, countMap.get(String(group._id)) || 0)
    ),
    ungroupedCount,
    stations: stations.map((station) => station.name),
  };
}

export default async function GroupsPage() {
  let data = null;
  let error = null;

  try {
    data = await loadGroups();
  } catch (loadError) {
    error = loadError;
  }

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Menu groups</h1>
          <p>
            Create a group, then add menu items into it. Groups drive the
            ordering screen&apos;s sections. Set a <strong>station</strong> per
            group so every item in it prints at that station — the POS Hub then
            only has to map each station to a printer.
          </p>
        </div>
      </div>

      {error ? (
        <ConfigError error={error} />
      ) : (
        <GroupManager
          groups={data.groups}
          stations={data.stations}
          ungroupedCount={data.ungroupedCount}
        />
      )}
    </>
  );
}
