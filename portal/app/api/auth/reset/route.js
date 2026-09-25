import { NextResponse } from 'next/server';

import { dbConnect } from '@/lib/mongodb';
import { withApiError } from '@/lib/api';
import { HttpError, findUserByResetToken, setUserPassword } from '@/lib/auth';

export const dynamic = 'force-dynamic';

async function reset(request) {
  await dbConnect();

  let body;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const token = String(body?.token || '').trim();
  const user = await findUserByResetToken(token);
  if (!user) {
    throw new HttpError(
      400,
      'This reset link is invalid or has expired. Request a new one.'
    );
  }

  await setUserPassword(user, body?.password);

  return NextResponse.json({ ok: true });
}

export const POST = withApiError(reset);
