import { NextResponse } from 'next/server';

import { withApiError } from '@/lib/api';
import { endSession } from '@/lib/auth';

export const dynamic = 'force-dynamic';

async function logout() {
  await endSession();
  return NextResponse.json({ ok: true });
}

export const POST = withApiError(logout);
