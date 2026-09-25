import mongoose from 'mongoose';

/// Portal login. Usernames are unique across the whole portal (one person may
/// manage several restaurants with separate accounts), and each user belongs
/// to exactly one tenant.
const UserSchema = new mongoose.Schema(
  {
    tenant: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'Tenant',
      required: true,
      index: true,
    },
    username: {
      type: String,
      required: true,
      unique: true,
      lowercase: true,
      trim: true,
    },
    /// Optional display name shown in the users list.
    name: { type: String, default: '', trim: true },
    /// `scrypt$<salt>$<hash>` — see lib/crypto.js
    passwordHash: { type: String, required: true },
    role: {
      type: String,
      enum: ['superadmin', 'owner', 'staff'],
      default: 'owner',
    },
    /// Deactivated accounts cannot sign in or use existing sessions.
    active: { type: Boolean, default: true },
    lastLoginAt: { type: Date, default: null },
    /// Password-reset request (stored hashed; the raw value only goes in the email).
    resetTokenHash: { type: String, default: null },
    resetTokenExpiresAt: { type: Date, default: null },
    /// Bumped on password change / deactivation to invalidate old sessions.
    sessionVersion: { type: Number, default: 0 },
  },
  { timestamps: true, collection: 'users' }
);

export default mongoose.models.User || mongoose.model('User', UserSchema);
