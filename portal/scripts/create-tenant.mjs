import mongoose from 'mongoose';
import Tenant from '../lib/models/Tenant.js';
import User from '../lib/models/User.js';
import { hashPassword, randomApiKey } from '../lib/crypto.js';
import { connectDb, readArg } from './tenant.mjs';

// Creates (or updates) a restaurant account and its first portal login.
//
//   node --env-file-if-exists=.env.local scripts/create-tenant.mjs \
//     --name "Warong Pak Jabit" --slug warong \
//     --username owner --password "super-secret"
//
// Re-running with the same slug updates the name and, when --password is given,
// resets that user's password. Pass --api-key to pin a known key instead of a
// freshly generated one.

const uri = process.env.MONGODB_URI;
const dbName = process.env.MONGODB_DB || undefined;

function slugify(value) {
  return String(value || '')
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}

async function main() {
  await connectDb(uri, dbName);
  console.log(`Connected to ${dbName || '(default database)'}`);

  const name = readArg('--name') || 'Warong';
  const slug = slugify(readArg('--slug') || name);
  const username = String(readArg('--username') || 'owner').trim().toLowerCase();
  const password = readArg('--password') || '';
  const requestedRole = readArg('--role') || 'owner';
  const role = ['owner', 'staff', 'superadmin'].includes(requestedRole)
    ? requestedRole
    : 'owner';
  const pinnedKey = readArg('--api-key');

  if (!slug) {
    throw new Error('A slug is required (use --slug).');
  }

  let tenant = await Tenant.findOne({ slug });
  if (!tenant) {
    tenant = await Tenant.create({
      name,
      slug,
      apiKey: pinnedKey || randomApiKey(),
      active: true,
    });
    console.log(`Created tenant "${tenant.name}" (${tenant.slug})`);
  } else {
    tenant.name = name;
    if (pinnedKey) tenant.apiKey = pinnedKey;
    await tenant.save();
    console.log(`Updated tenant "${tenant.name}" (${tenant.slug})`);
  }

  const existingUser = await User.findOne({ username });
  if (existingUser && String(existingUser.tenant) !== String(tenant._id)) {
    // Usernames are global; never steal an account from another restaurant.
    throw new Error(
      `Username "${username}" already belongs to another restaurant. ` +
        `Pass a different --username.`
    );
  }

  if (!existingUser) {
    if (!password) {
      throw new Error(
        `User "${username}" does not exist. Pass --password to create it.`
      );
    }
    await User.create({
      tenant: tenant._id,
      username,
      passwordHash: hashPassword(password),
      role,
    });
    console.log(`Created ${role} user "${username}"`);
  } else {
    existingUser.tenant = tenant._id;
    existingUser.role = role;
    if (password) existingUser.passwordHash = hashPassword(password);
    await existingUser.save();
    console.log(
      `Updated user "${username}"${password ? ' (password reset)' : ''}`
    );
  }

  console.log('');
  console.log('Tenant id :', String(tenant._id));
  console.log('Slug      :', tenant.slug);
  console.log('API key   :', tenant.apiKey);
  console.log('Login     :', username, '/', password ? '(as given)' : '(unchanged)');
  console.log('');
  console.log(
    'Give the POS Hub this menu URL:\n' +
      `  http://<portal-host>:3000/api/export?format=grouped&key=${tenant.apiKey}`
  );
}

main()
  .catch((error) => {
    console.error('create-tenant failed:', error.message);
    process.exitCode = 1;
  })
  .finally(async () => {
    await mongoose.disconnect().catch(() => {});
  });
