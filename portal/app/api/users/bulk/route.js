import { NextResponse } from 'next/server';
import mongoose from 'mongoose';

import { dbConnect } from '@/lib/mongodb';
import User from '@/lib/models/User';
import { withApiError } from '@/lib/api';
import { requireAdmin } from '@/lib/auth';
import { canManageUser } from '@/lib/users';

export const dynamic = 'force-dynamic';

// Bulk delete portal users. The same rules as the single delete apply: you
// cannot remove yourself, another restaurant's users, or the last superadmin.
//   POST { ids: ["<userId>", ...] }
async function bulkDeleteUsers(request) {
  await dbConnect();
  const { user: actor } = await requireAdmin('owner');

  let body;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const ids = Array.isArray(body?.ids)
    ? [...new Set(body.ids.map(String))].filter((id) => mongoose.isValidObjectId(id))
    : [];
  if (ids.length === 0) {
    return NextResponse.json({ error: 'ids must be a non-empty array' }, { status: 400 });
  }

  const targets = await User.find({ _id: { $in: ids } });

  let deleted = 0;
  const blocked = [];
  for (const target of targets) {
    if (String(target._id) === String(actor._id)) {
      blocked.push(`${target.username} (you)`);
      continue;
    }
    if (!canManageUser(actor, target)) {
      blocked.push(`${target.username} (not allowed)`);
      continue;
    }
    if (target.role === 'superadmin') {
      const remaining = await User.countDocuments({
        role: 'superadmin',
        active: true,
      });
      if (remaining <= 1) {
        blocked.push(`${target.username} (last superadmin)`);
        continue;
      }
    }
    await target.deleteOne();
    deleted += 1;
  }

  return NextResponse.json({
    ok: true,
    deleted,
    skipped: ids.length - deleted,
    blocked,
  });
}

export const POST = withApiError(bulkDeleteUsers);
