import { NextResponse } from 'next/server';
import { dbConnect } from '@/lib/mongodb';
import Station from '@/lib/models/Station';
import MenuItem from '@/lib/models/MenuItem';
import MenuGroup from '@/lib/models/MenuGroup';
import { findStation } from '@/lib/menu-service';
import { validateStation } from '@/lib/validate';
import { withApiError } from '@/lib/api';
import { requireSession } from '@/lib/auth';

export const dynamic = 'force-dynamic';

async function updateStation(request, { params }) {
  await dbConnect();
  const { tenantId } = await requireSession();
  const { id } = await params;

  let body;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const station = await findStation(tenantId, id);
  if (!station) {
    return NextResponse.json({ error: 'Station not found' }, { status: 404 });
  }

  const { values, errors } = validateStation(body, { partial: true });
  if (errors.length) {
    return NextResponse.json({ error: errors.join('; '), errors }, { status: 400 });
  }
  if (Object.keys(values).length === 0) {
    return NextResponse.json({ error: 'No supported fields to update' }, { status: 400 });
  }

  const previousName = station.name;

  if (values.name && values.name !== previousName) {
    const duplicate = await Station.findOne({
      tenant: tenantId,
      name: values.name,
      _id: { $ne: station._id },
    });
    if (duplicate) {
      return NextResponse.json(
        { error: `Station ${values.name} already exists` },
        { status: 409 }
      );
    }
  }

  Object.assign(station, values);
  await station.save();

  let renamedItems = 0;
  let renamedGroups = 0;
  if (values.name && values.name !== previousName) {
    const itemResult = await MenuItem.updateMany(
      { tenant: tenantId, station: previousName },
      { $set: { station: values.name } }
    );
    renamedItems = itemResult.modifiedCount || 0;

    // A group can pin its own station, and the export prefers it over the
    // item's, so the rename has to follow through to groups too — otherwise the
    // apps keep seeing the old station name.
    const groupResult = await MenuGroup.updateMany(
      { tenant: tenantId, station: previousName },
      { $set: { station: values.name } }
    );
    renamedGroups = groupResult.modifiedCount || 0;
  }

  return NextResponse.json({
    station: {
      id: String(station._id),
      name: station.name,
      printerName: station.printerName || '',
      sortOrder: station.sortOrder,
    },
    renamedItems,
    renamedGroups,
  });
}

async function deleteStation(_request, { params }) {
  await dbConnect();
  const { tenantId } = await requireSession();
  const { id } = await params;

  const station = await findStation(tenantId, id);
  if (!station) {
    return NextResponse.json({ error: 'Station not found' }, { status: 404 });
  }

  const itemCount = await MenuItem.countDocuments({
    tenant: tenantId,
    station: station.name,
  });
  if (itemCount > 0) {
    return NextResponse.json(
      {
        error: `Cannot delete ${station.name}: ${itemCount} menu item(s) still use it. Move or delete those items first.`,
        itemCount,
      },
      { status: 409 }
    );
  }

  await station.deleteOne();

  return NextResponse.json({ ok: true, id: String(station._id), name: station.name });
}

export const PATCH = withApiError(updateStation);
export const DELETE = withApiError(deleteStation);
