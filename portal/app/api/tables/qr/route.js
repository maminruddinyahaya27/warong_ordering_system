import { NextResponse } from 'next/server';
import QRCode from 'qrcode';

import { withApiError } from '@/lib/api';
import { requireSession } from '@/lib/auth';

export const dynamic = 'force-dynamic';

// Renders a QR code PNG for the signed-in restaurant.
//   GET /api/tables/qr?text=<url>
async function tableQr(request) {
  await requireSession();

  const { searchParams } = new URL(request.url);
  const text = (searchParams.get('text') || '').trim();
  if (!text || text.length > 500) {
    return NextResponse.json({ error: 'text is required' }, { status: 400 });
  }

  const buffer = await QRCode.toBuffer(text, {
    type: 'png',
    width: 640,
    margin: 2,
    errorCorrectionLevel: 'M',
  });

  return new NextResponse(buffer, {
    headers: {
      'Content-Type': 'image/png',
      'Cache-Control': 'private, max-age=3600',
    },
  });
}

export const GET = withApiError(tableQr);
