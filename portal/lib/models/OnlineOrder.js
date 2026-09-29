import mongoose from 'mongoose';

/// One item inside a customer's QR order. The price/name/station are snapshots
/// taken when the order was placed, so later menu edits cannot change it.
const OnlineOrderItemSchema = new mongoose.Schema(
  {
    sku: { type: String, required: true },
    name: { type: String, required: true },
    qty: { type: Number, required: true },
    price: { type: Number, required: true },
    station: { type: String, default: '' },
    note: { type: String, default: '' },
  },
  { _id: false }
);

/// An order placed by a customer from a table QR. The POS Hub polls for
/// `pending` orders, merges them into the table's bill, then marks them
/// `imported`.
const OnlineOrderSchema = new mongoose.Schema(
  {
    tenant: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'Tenant',
      required: true,
      index: true,
    },
    table: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'Table',
      required: true,
    },
    tableLabel: { type: String, default: '' },
    /// Short code the customer can quote, e.g. `K7F2Q9`.
    ref: { type: String, required: true },
    items: { type: [OnlineOrderItemSchema], default: [] },
    note: { type: String, default: '' },
    total: { type: Number, default: 0 },
    status: {
      type: String,
      enum: ['pending', 'imported', 'rejected'],
      default: 'pending',
    },
    rejectReason: { type: String, default: '' },
    hubOrderNo: { type: String, default: '' },
    importedAt: { type: Date, default: null },
  },
  { timestamps: true, collection: 'online_orders' }
);

OnlineOrderSchema.index({ tenant: 1, status: 1, createdAt: 1 });
OnlineOrderSchema.index({ tenant: 1, ref: 1 }, { unique: true });

export default mongoose.models.OnlineOrder ||
  mongoose.model('OnlineOrder', OnlineOrderSchema);
