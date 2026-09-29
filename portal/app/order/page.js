import CustomerOrder from '@/components/CustomerOrder';

export const dynamic = 'force-dynamic';

export const metadata = {
  title: 'Order at your table',
};

export default async function OrderPage({ searchParams }) {
  const resolved = (await searchParams) || {};

  // Current format: ?t=<tenantId>&table=<tableToken>.
  // Earlier QR codes used ?tenant=<slug>&t=<token>; keep those working.
  const hasTable = typeof resolved.table === 'string' && resolved.table !== '';
  const tenantRef = hasTable
    ? typeof resolved.t === 'string'
      ? resolved.t
      : ''
    : typeof resolved.tenant === 'string'
      ? resolved.tenant
      : '';
  const tableToken = hasTable
    ? resolved.table
    : typeof resolved.t === 'string'
      ? resolved.t
      : '';

  return (
    <div style={{ maxWidth: 560, margin: '0 auto', padding: '12px 14px 0' }}>
      {tenantRef && tableToken ? (
        <CustomerOrder tenantRef={tenantRef} tableToken={tableToken} />
      ) : (
        <div className="notice notice-error">
          This link is incomplete. Please scan the QR code on your table again.
        </div>
      )}
    </div>
  );
}
