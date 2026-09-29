'use client';

import Link from 'next/link';
import { usePathname, useRouter } from 'next/navigation';

const LINKS = [
  { href: '/', label: 'Dashboard' },
  { href: '/groups', label: 'Groups' },
  { href: '/menu', label: 'Menu & Prices' },
  { href: '/tables', label: 'Tables & QR' },
  { href: '/stations', label: 'Stations' },
  { href: '/history', label: 'Price History' },
  { href: '/users', label: 'Users' },
  { href: '/settings', label: 'Settings' },
];

// Screens with no portal navigation: the auth pages and the public customer
// ordering page that a table QR opens.
const SIGNED_OUT_PATHS = [
  '/login',
  '/forgot-password',
  '/reset-password',
  '/order',
];

export default function Navbar() {
  const pathname = usePathname();
  const router = useRouter();

  function isActive(href) {
    if (href === '/') return pathname === '/';
    return pathname === href || pathname.startsWith(`${href}/`);
  }

  async function signOut() {
    await fetch('/api/auth/logout', { method: 'POST' });
    router.replace('/login');
    router.refresh();
  }

  // The signed-out screens have no navigation.
  if (SIGNED_OUT_PATHS.includes(pathname)) return null;

  return (
    <header className="topbar">
      <Link href="/" className="brand">
        Warong <small>Menu &amp; Price Portal</small>
      </Link>
      <nav className="nav">
        {LINKS.map((link) => (
          <Link
            key={link.href}
            href={link.href}
            className={isActive(link.href) ? 'active' : ''}
          >
            {link.label}
          </Link>
        ))}
      </nav>
      <div className="topbar-actions">
        <button type="button" className="btn btn-sm" onClick={signOut}>
          Sign out
        </button>
      </div>
    </header>
  );
}
