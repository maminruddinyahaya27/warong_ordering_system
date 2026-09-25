import { NextResponse } from 'next/server';

import { dbConnect } from '@/lib/mongodb';
import User from '@/lib/models/User';
import { withApiError } from '@/lib/api';
import { createPasswordReset } from '@/lib/auth';
import { isMailConfigured, sendPasswordResetEmail } from '@/lib/email';

export const dynamic = 'force-dynamic';

// Build the reset link from a trusted origin. Prefer PORTAL_BASE_URL; otherwise
// accept only a private/local Host, so an attacker cannot point the emailed
// link at their own domain (reset-link poisoning) and steal the token.
function resolveOrigin(request) {
  const configured = (process.env.PORTAL_BASE_URL || process.env.APP_ORIGIN || '')
    .trim()
    .replace(/\/+$/, '');
  if (configured) return configured;

  const host = (request.headers.get('x-forwarded-host') || request.headers.get('host') || '')
    .split(',')[0]
    .trim();
  if (!host) return '';

  const hostname = host.replace(/:\d+$/, '').replace(/^\[|\]$/g, '');
  const isPrivate =
    hostname === 'localhost' ||
    hostname === '127.0.0.1' ||
    hostname === '::1' ||
    hostname.endsWith('.local') ||
    /^10\./.test(hostname) ||
    /^192\.168\./.test(hostname) ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(hostname);
  if (!isPrivate) return '';

  const proto = request.headers.get('x-forwarded-proto') || 'http';
  return `${proto}://${host}`;
}

async function forgot(request) {
  await dbConnect();

  let body;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const username = String(body?.username || '').trim().toLowerCase();

  // Always answer the same way, so the form cannot be used to discover which
  // email addresses have accounts.
  if (username) {
    const user = await User.findOne({ username, active: true });
    if (user) {
      const token = await createPasswordReset(user);
      const origin = resolveOrigin(request);
      if (origin) {
        const resetUrl = `${origin}/reset-password?token=${encodeURIComponent(token)}`;
        try {
          await sendPasswordResetEmail({
            to: user.username,
            name: user.name,
            resetUrl,
          });
        } catch (mailError) {
          console.error('[forgot-password] email failed:', mailError.message);
        }
      } else {
        console.error(
          '[forgot-password] refusing to build a reset link for an untrusted host; ' +
            'set PORTAL_BASE_URL to enable reset emails'
        );
      }
    }
  }

  return NextResponse.json({ ok: true, mailConfigured: isMailConfigured() });
}

export const POST = withApiError(forgot);
