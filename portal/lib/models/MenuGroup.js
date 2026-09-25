import mongoose from 'mongoose';

const MenuGroupSchema = new mongoose.Schema(
  {
    tenant: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'Tenant',
      required: true,
      index: true,
    },
    name: { type: String, required: true, trim: true },
    description: { type: String, default: '', trim: true },
    color: { type: String, default: '', trim: true },
    // Station this group's items are printed at. When set it overrides each
    // item's own station, so the hub only needs station -> printer mapping.
    station: { type: String, default: '', trim: true },
    sortOrder: { type: Number, default: 0 },
  },
  { timestamps: true, collection: 'menu_groups' }
);

// Group names are unique within a restaurant.
MenuGroupSchema.index({ tenant: 1, name: 1 }, { unique: true });
MenuGroupSchema.index({ tenant: 1, sortOrder: 1, name: 1 });

export default mongoose.models.MenuGroup ||
  mongoose.model('MenuGroup', MenuGroupSchema);
