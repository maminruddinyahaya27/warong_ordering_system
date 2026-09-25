import mongoose from 'mongoose';

const SettingSchema = new mongoose.Schema(
  {
    tenant: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'Tenant',
      required: true,
      index: true,
    },
    key: { type: String, required: true, default: 'global' },
    restaurantName: { type: String, default: 'Warong', trim: true },
    currency: { type: String, default: 'RM', trim: true },
    taxRate: { type: Number, default: 0.1, min: 0, max: 1 },
    updatedBy: { type: String, default: '', trim: true },
  },
  { timestamps: true, collection: 'settings' }
);

// One settings document per restaurant.
SettingSchema.index({ tenant: 1, key: 1 }, { unique: true });

export default mongoose.models.Setting ||
  mongoose.model('Setting', SettingSchema);
