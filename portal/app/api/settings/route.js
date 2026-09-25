import { NextResponse } from 'next/server';
import { dbConnect } from '@/lib/mongodb';
import { getSettings, serializeSettings } from '@/lib/menu-service';
import { validateSettings } from '@/lib/validate';
import { withApiError } from '@/lib/api';
import { requireSession } from '@/lib/auth';

export const dynamic = 'force-dynamic';

async function readSettings() {
  await dbConnect();
  const { tenantId } = await requireSession();
  const settings = await getSettings(tenantId);
  return NextResponse.json({ settings: serializeSettings(settings) });
}

async function updateSettings(request) {
  await dbConnect();
  const { tenantId } = await requireSession();

  let body;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const { values, errors } = validateSettings(body);
  if (errors.length) {
    return NextResponse.json({ error: errors.join('; '), errors }, { status: 400 });
  }
  if (Object.keys(values).length === 0) {
    return NextResponse.json({ error: 'No supported fields to update' }, { status: 400 });
  }

  const settings = await getSettings(tenantId);
  Object.assign(settings, values);
  await settings.save();

  return NextResponse.json({ settings: serializeSettings(settings) });
}

export const GET = withApiError(readSettings);
export const PATCH = withApiError(updateSettings);
