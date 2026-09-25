import mongoose from 'mongoose';

/// A restaurant account. Every menu item, group, station, setting and price
/// change belongs to exactly one tenant, so one portal deployment can serve
/// several restaurants without seeing each other's data.
const TenantSchema = new mongoose.Schema(
  {
    name: { type: String, required: true, trim: true },
    slug: { type: String, required: true, unique: true, lowercase: true, trim: true },
    // Used by the POS Hub (and scripts) to pull the menu over HTTP.
    apiKey: { type: String, required: true, unique: true, index: true },
    active: { type: Boolean, default: true },
  },
  { timestamps: true, collection: 'tenants' }
);

export default mongoose.models.Tenant || mongoose.model('Tenant', TenantSchema);
