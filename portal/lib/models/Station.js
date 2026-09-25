import mongoose from 'mongoose';

const StationSchema = new mongoose.Schema(
  {
    tenant: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'Tenant',
      required: true,
      index: true,
    },
    name: { type: String, required: true, trim: true },
    printerName: { type: String, default: '', trim: true },
    sortOrder: { type: Number, default: 0 },
  },
  { timestamps: true, collection: 'stations' }
);

// Station names are unique within a restaurant.
StationSchema.index({ tenant: 1, name: 1 }, { unique: true });

export default mongoose.models.Station ||
  mongoose.model('Station', StationSchema);
