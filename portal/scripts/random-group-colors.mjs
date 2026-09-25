import mongoose from 'mongoose';
import MenuGroup from '../lib/models/MenuGroup.js';

// Assigns a random colour to every group that does not have one yet.
// Existing colours are left untouched, and new colours avoid duplicates.
//
//   node --env-file-if-exists=.env.local scripts/random-group-colors.mjs

const uri = process.env.MONGODB_URI;
const dbName = process.env.MONGODB_DB || undefined;

if (!uri) {
  console.error('MONGODB_URI is not set. Add it to .env.local or export it first.');
  process.exit(1);
}

function hslToHex(h, s, l) {
  const sat = s / 100;
  const light = l / 100;
  const k = (n) => (n + h / 30) % 12;
  const a = sat * Math.min(light, 1 - light);
  const f = (n) => {
    const value = light - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
    return Math.round(255 * value)
      .toString(16)
      .padStart(2, '0');
  };
  return `#${f(0)}${f(8)}${f(4)}`.toUpperCase();
}

async function main() {
  await mongoose.connect(uri, { dbName });
  console.log(`Connected to ${dbName || '(default database)'}`);

  const all = await MenuGroup.find({}).lean();
  const used = new Set(all.map((group) => group.color).filter(Boolean));
  const blank = all.filter((group) => !group.color);

  if (blank.length === 0) {
    console.log('Every group already has a colour. Nothing to do.');
    return;
  }

  for (const group of blank) {
    let color;
    do {
      // Random hue, fixed saturation/lightness so the tint stays readable
      // on the light card backgrounds.
      color = hslToHex(Math.floor(Math.random() * 360), 65, 38);
    } while (used.has(color));
    used.add(color);
    await MenuGroup.updateOne({ _id: group._id }, { $set: { color } });
    console.log(`  ${group.name}: ${color}`);
  }

  console.log(`Assigned colours to ${blank.length} group(s).`);
}

main()
  .catch((error) => {
    console.error('Failed:', error.message);
    process.exitCode = 1;
  })
  .finally(async () => {
    await mongoose.disconnect().catch(() => {});
  });
