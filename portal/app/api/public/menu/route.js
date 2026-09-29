import { NextResponse } from 'next/server';

import { withApiError } from '@/lib/api';
import { buildPublicMenu, resolveTable } from '@/lib/public-ordering';

export const dynamic = 'force-dynamic';

// Public: the menu a customer sees after scanning a table QR.
//   GET /api/public/menu?t=<tenantId>&table=<tableToken>
async function getPublicMenu(request) {
  const { searchParams } = new URL(request.url);
  const { tenant, table } = await resolveTable({
    tenantRef: searchParams.get('t'),
    tableToken: searchParams.get('table'),
  });

  const menu = await buildPublicMenu(tenant, table);
  return NextResponse.json(menu);
}

export const GET = withApiError(getPublicMenu);
