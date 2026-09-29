import { NextResponse } from 'next/server';

/// Edge-safe session check: verifies the signed cookie without any database or
/// Node.js API, then lets the page/route do its own authoritative checks.
///
/// Next.js 16 runs this file as the request proxy (formerly `middleware.js`).
const SESSION_COOKIE = 'portal_session';

// Public: the login screen itself, the auth endpoints, and the menu feed
// (which authenticates with a tenant API key instead of a session).
const PUBLIC_PREFIXES = [
  '/login',
  '/forgot-password',
  '/reset-password',
  // Customer self-ordering from a table QR code.
  '/order',
  '/api/public',
  '/api/auth',
  // Menu feed and QR-order polling authenticate with the tenant API key.
  '/api/export',
  '/api/online-orders',
];

async function verifyToken(token, secret) {
  const [payload, signature] = String(token || '').split('.');
  if (!payload || !signature) return null;

  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const mac = await crypto.subtle.sign(
    'HMAC',
    key,
    new TextEncoder().encode(payload)
  );

  let binary = '';
  new Uint8Array(mac).forEach((byte) => {
    binary += String.fromCharCode(byte);
  });
  const expected = btoa(binary)
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');

  if (expected.length !== signature.length) return null;
  let diff = 0;
  for (let index = 0; index < expected.length; index += 1) {
    diff |= expected.charCodeAt(index) ^ signature.charCodeAt(index);
  }
  if (diff !== 0) return null;

  try {
    // Edge runtime has no Buffer — decode base64url with atob.
    const padded = payload.replace(/-/g, '+').replace(/_/g, '/');
    const json = decodeURIComponent(
      atob(padded + '='.repeat((4 - (padded.length % 4)) % 4))
        .split('')
        .map((char) => `%${`00${char.charCodeAt(0).toString(16)}`.slice(-2)}`)
        .join('')
    );
    const data = JSON.parse(json);
    if (!data?.uid || !data?.tid || !data?.exp) return null;
    if (Date.now() > data.exp) return null;
    return data;
  } catch {
    return null;
  }
}

export async function proxy(request) {
  const { pathname } = request.nextUrl;

  if (PUBLIC_PREFIXES.some((prefix) => pathname.startsWith(prefix))) {
    return NextResponse.next();
  }

  const secret = process.env.AUTH_SECRET;
  const token = request.cookies.get(SESSION_COOKIE)?.value;
  const session = secret && token ? await verifyToken(token, secret) : null;

  if (session) return NextResponse.next();

  if (pathname.startsWith('/api/')) {
    return NextResponse.json(
      { error: 'Authentication required' },
      { status: 401 }
    );
  }

  const loginUrl = request.nextUrl.clone();
  loginUrl.pathname = '/login';
  loginUrl.search = '';
  if (pathname !== '/') {
    loginUrl.searchParams.set('next', pathname);
  }
  return NextResponse.redirect(loginUrl);
}

export const config = {
  matcher: [
    // Everything except Next assets, the favicon and static files (the
    // mockups in /public stay reachable for staff devices).
    '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:png|jpg|jpeg|gif|svg|ico|css|js|map|txt|webmanifest|html)$).*)',
  ],
};
