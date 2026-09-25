import mongoose from 'mongoose';

const MenuItemSchema = new mongoose.Schema(
  {
    tenant: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'Tenant',
      required: true,
      index: true,
    },
    sku: { type: String, required: true, trim: true },
    name: { type: String, required: true, trim: true },
    price: { type: Number, required: true, min: 0 },
    station: { type: String, required: true, trim: true, default: 'Kitchen' },
    group: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'MenuGroup',
      default: null,
      index: true,
    },
    groupName: { type: String, default: '', trim: true, index: true },
    options: { type: String, default: '', trim: true },
    description: { type: String, default: '', trim: true },
    available: { type: Boolean, default: true },
    sortOrder: { type: Number, default: 0 },
  },
  { timestamps: true, collection: 'menu_items' }
);

// SKUs are unique per restaurant, not globally.
MenuItemSchema.index({ tenant: 1, sku: 1 }, { unique: true });
MenuItemSchema.index({ tenant: 1, station: 1, sortOrder: 1, name: 1 });

export default mongoose.models.MenuItem ||
  mongoose.model('MenuItem', MenuItemSchema);
