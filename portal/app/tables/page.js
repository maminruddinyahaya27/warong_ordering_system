import { headers } from 'next/headers';

import TableManager from '@/components/TableManager';
import { requireAdmin } from '@/lib/auth';
import { dbConnect } from '@/lib/mongodb';
import Table from '@/lib/models/Table';
import { publicBase, serializeTable } from '@/lib/tables';

export const dynamic = 'force-dynamic';

export default async function TablesPage() {
  let initial = null;

  try {
    await dbConnect();
    const { tenant } = await requireAdmin('owner');
    const headerList = await headers();
    const base = publicBase({ headers: headerList });
    const tables = await Table.find({ tenant: tenant._id })
      .sort({ sortOrder: 1, label: 1 })
      .lean();

    initial = {
      tables: tables.map((table) =>
        serializeTable(table, String(tenant._id), base)
      ),
    };
  } catch {
    initial = null;
  }

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Tables &amp; QR</h1>
          <p>
            Print a QR code for each table. Customers scan it to open your menu
            and send their order to the POS Hub, then pay at the counter.
          </p>
        </div>
      </div>

      {initial ? (
        <TableManager initial={initial} />
      ) : (
        <div className="notice notice-error">
          You need an owner or superadmin account to manage tables.
        </div>
      )}
    </>
  );
}
