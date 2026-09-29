import mongoose from 'mongoose';

/// A physical table a customer can order from by scanning its QR code.
/// Each table has a random [token]; the QR points at
/// `<portal>/order?tenant=<slug>&t=<token>`, so a code from one restaurant can
/// never be used at another.
const TableSchema = new mongoose.Schema(
  {
    tenant: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'Tenant',
      required: true,
      index: true,
    },
    label: { type: String, required: true, trim: true },
    token: { type: String, required: true, unique: true, index: true },
    active: { type: Boolean, default: true },
    sortOrder: { type: Number, default: 0 },
  },
  { timestamps: true, collection: 'tables' }
);

TableSchema.index({ tenant: 1, label: 1 }, { unique: true });

export default mongoose.models.Table || mongoose.model('Table', TableSchema);
