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
    // Prints here; empty means the item's group routes it (and if neither is
    // set the till sends it to the kitchen's default station).
    station: { type: String, default: '', trim: true },
    group: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'MenuGroup',
      default: null,
      index: true,
    },
    groupName: { type: String, default: '', trim: true, index: true },
    options: { type: String, default: '', trim: true },
    // Parent groups this item is an add-on for: when one of them is on the same
    // order, this item prints on that group's station (e.g. Kari Kambing with a
    // Roti Canai prints at the griddle; Sambal Sardin is left empty and stays
    // in the kitchen).
    addOnFor: { type: [String], default: [] },
    // When true the item cannot be ordered on its own: an add-on must be picked
    // first (e.g. Nasi Lemak + Lauk).
    requireAddOn: { type: Boolean, default: false },
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
