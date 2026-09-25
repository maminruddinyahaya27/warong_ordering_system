import { dbConnect } from '@/lib/mongodb';
import { getSettings, serializeSettings } from '@/lib/menu-service';
import SettingsForm from '@/components/SettingsForm';
import ConfigError from '@/components/ConfigError';
import { requireTenant } from '@/lib/auth';

export const dynamic = 'force-dynamic';

export default async function SettingsPage() {
  let settings = null;
  let error = null;

  try {
    await dbConnect();
    const tenant = await requireTenant();
    const doc = await getSettings(tenant);
    settings = serializeSettings(doc);
  } catch (loadError) {
    error = loadError;
  }

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Settings</h1>
          <p>Restaurant identity, currency and tax.</p>
        </div>
      </div>

      {error ? <ConfigError error={error} /> : <SettingsForm settings={settings} />}
    </>
  );
}
