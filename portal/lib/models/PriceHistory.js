import mongoose from 'mongoose';

const PriceHistorySchema = new mongoose.Schema(
  {
    tenant: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'Tenant',
      required: true,
      index: true,
    },
    itemId: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'MenuItem',
      index: true,
    },
    sku: { type: String, required: true, trim: true, index: true },
    name: { type: String, required: true, trim: true },
    action: {
      type: String,
      required: true,
      enum: ['create', 'update', 'delete'],
    },
    oldPrice: { type: Number, default: null },
    newPrice: { type: Number, default: null },
    station: { type: String, default: '' },
    changedBy: { type: String, default: 'portal', trim: true },
    note: { type: String, default: '', trim: true },
  },
  { timestamps: true, collection: 'price_history' }
);

PriceHistorySchema.index({ tenant: 1, createdAt: -1 });

export default mongoose.models.PriceHistory ||
  mongoose.model('PriceHistory', PriceHistorySchema);
