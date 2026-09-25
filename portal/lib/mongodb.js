import mongoose from 'mongoose';

const MONGODB_URI = process.env.MONGODB_URI;

let cached = global._warongMongooseCache;
if (!cached) {
  cached = global._warongMongooseCache = { conn: null, promise: null };
}

function assertConfigured() {
  if (!MONGODB_URI) {
    throw new Error(
      'MONGODB_URI is not set. Copy .env.example to .env.local and fill it in.'
    );
  }
  if (MONGODB_URI.includes('REPLACE_WITH_DB_PASSWORD')) {
    throw new Error(
      'MONGODB_URI still contains the placeholder REPLACE_WITH_DB_PASSWORD. ' +
        'Put the real database password in .env.local.'
    );
  }
}

export async function dbConnect() {
  assertConfigured();

  if (cached.conn) return cached.conn;

  if (!cached.promise) {
    cached.promise = mongoose
      .connect(MONGODB_URI, {
        bufferCommands: false,
        dbName: process.env.MONGODB_DB || undefined,
      })
      .then((m) => m);
  }

  try {
    cached.conn = await cached.promise;
  } catch (error) {
    cached.promise = null;
    throw error;
  }

  return cached.conn;
}

export default dbConnect;
