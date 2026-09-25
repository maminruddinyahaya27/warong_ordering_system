import { NextResponse } from 'next/server';

import { withApiError } from '@/lib/api';
import { authenticate, startSession } from '@/lib/auth';

export const dynamic = 'force-dynamic';

async function login(request) {
  let body;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const username = String(body?.username || '').trim();
  const password = String(body?.password || '');
  if (!username || !password) {
    return NextResponse.json(
      { error: 'Username and password are required' },
      { status: 400 }
    );
  }

  const found = await authenticate(username, password);
  if (!found) {
    // Same message for unknown user and wrong password.
    return NextResponse.json(
      { error: 'Wrong username or password' },
      { status: 401 }
    );
  }

  await startSession(found.user);
  return NextResponse.json({
    ok: true,
    tenant: { name: found.tenant.name, slug: found.tenant.slug },
  });
}

export const POST = withApiError(login);
