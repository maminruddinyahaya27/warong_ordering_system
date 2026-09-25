import { NextResponse } from 'next/server';
import { dbConnect } from '@/lib/mongodb';
import MenuItem from '@/lib/models/MenuItem';
import MenuGroup from '@/lib/models/MenuGroup';
import Station from '@/lib/models/Station';
import { getSettings } from '@/lib/menu-service';
import { withApiError } from '@/lib/api';
import { HttpError, tenantForRequest } from '@/lib/auth';

export const dynamic = 'force-dynamic';

const UNGROUPED_LABEL = 'Ungrouped';

function groupColorMap(groups) {
  const map = new Map();
  for (const group of groups) {
    if (group.color) map.set(group.name, group.color);
  }
  return map;
}

// A group's station (set in the portal) overrides each item's own station, so
// the POS Hub only needs station -> printer mapping.
function groupStationMap(groups) {
  const map = new Map();
  for (const group of groups) {
    if (group.station) map.set(group.name, group.station);
  }
  return map;
}

function toArrayEntry(item, colorByName, stationByName) {
  const group = item.groupName || UNGROUPED_LABEL;
  const entry = {
    id: item.sku,
    name: item.name,
    price: item.price,
    station: stationByName?.get(group) || item.station,
    group,
    available: item.available !== false,
  };
  const color = colorByName?.get(group);
  if (color) entry.groupColor = color;
  if (item.options) entry.options = item.options;
  return entry;
}

async function getExport(request) {
  await dbConnect();

  const tenant = await tenantForRequest(request);
  if (!tenant) {
    throw new HttpError(
      401,
      'A tenant API key (X-Api-Key, Basic, or ?key=) or a portal session is required'
    );
  }

  const { searchParams } = new URL(request.url);
  const format = (searchParams.get('format') || 'array').toLowerCase();
  const station = (searchParams.get('station') || '').trim();
  const group = (searchParams.get('group') || '').trim();
  const availableOnly = searchParams.get('availableOnly') === '1';
  const download = searchParams.get('download') === '1';

  const query = { tenant: tenant._id };
  if (station) query.station = station;
  if (availableOnly) query.available = true;

  if (group) {
    if (group === 'none' || group === 'ungrouped') {
      query.group = null;
    } else {
      query.groupName = group;
    }
  }

  const [items, settings, groups, stations] = await Promise.all([
    MenuItem.find(query).sort({ sortOrder: 1, name: 1 }).lean(),
    getSettings(tenant),
    MenuGroup.find({ tenant: tenant._id }).sort({ sortOrder: 1, name: 1 }).lean(),
    Station.find({ tenant: tenant._id }).sort({ sortOrder: 1, name: 1 }).lean(),
  ]);

  let payload;

  const colorByName = groupColorMap(groups);
  const stationByName = groupStationMap(groups);

  if (format === 'grouped') {
    const buckets = new Map();
    for (const menuGroup of groups) {
      buckets.set(menuGroup.name, []);
    }
    buckets.set(UNGROUPED_LABEL, []);

    for (const item of items) {
      const key = item.groupName || UNGROUPED_LABEL;
      if (!buckets.has(key)) buckets.set(key, []);
      buckets.get(key).push(toArrayEntry(item, colorByName, stationByName));
    }

    payload = [...buckets.entries()]
      .filter(([, groupItems]) => groupItems.length > 0)
      .map(([name, groupItems]) => ({
        name,
        color: colorByName.get(name) || '',
        station: stationByName.get(name) || '',
        items: groupItems,
      }));
  } else if (format === 'object') {
    payload = {};
    for (const item of items) {
      const group = item.groupName || UNGROUPED_LABEL;
      const entry = {
        price: item.price,
        station: stationByName.get(group) || item.station,
        group,
      };
      const color = colorByName.get(group);
      if (color) entry.groupColor = color;
      if (item.options) entry.options = item.options;
      payload[item.name] = entry;
    }
  } else {
    payload = items.map((item) => toArrayEntry(item, colorByName, stationByName));
  }

  const body = JSON.stringify(
    {
      generatedAt: new Date().toISOString(),
      currency: settings.currency,
      taxRate: settings.taxRate,
      count: items.length,
      // The station list itself, so the POS Hub maps the same stations the
      // portal manages — including ones with no items yet.
      stations: stations.map((entry) => entry.name),
      menu: payload,
    },
    null,
    2
  );

  const headers = { 'Content-Type': 'application/json; charset=utf-8' };
  if (download) {
    const filename = `menu-${format}-${new Date().toISOString().slice(0, 10)}.json`;
    headers['Content-Disposition'] = `attachment; filename="${filename}"`;
  }

  return new NextResponse(body, { status: 200, headers });
}

export const GET = withApiError(getExport);
