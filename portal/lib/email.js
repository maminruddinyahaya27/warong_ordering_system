import nodemailer from 'nodemailer';

// Transactional email over Mailjet SMTP.
//
// Configure in portal/.env.local:
//   MAILJET_API_KEY=...        (SMTP username)
//   MAILJET_SECRET_KEY=...     (SMTP password / API secret)
//   MAIL_FROM=you@example.com  (a verified Mailjet sender)
//   MAIL_FROM_NAME=Warong Portal
//
// When these are missing, messages are logged to the server console instead of
// being sent, so the password-reset flow still works during development.

const SMTP_HOST = process.env.MAILJET_SMTP_HOST || 'in-v3.mailjet.com';
const SMTP_PORT = Number(process.env.MAILJET_SMTP_PORT || 587);

export function isMailConfigured() {
  return Boolean(
    process.env.MAILJET_API_KEY &&
      process.env.MAILJET_SECRET_KEY &&
      process.env.MAIL_FROM
  );
}

let transporter = null;

function getTransporter() {
  if (!transporter) {
    transporter = nodemailer.createTransport({
      host: SMTP_HOST,
      port: SMTP_PORT,
      secure: SMTP_PORT === 465,
      auth: {
        user: process.env.MAILJET_API_KEY,
        pass: process.env.MAILJET_SECRET_KEY,
      },
    });
  }
  return transporter;
}

function fromAddress() {
  const name = process.env.MAIL_FROM_NAME || 'Warong Portal';
  const address = process.env.MAIL_FROM;
  return address ? `"${name}" <${address}>` : name;
}

/// Sends one email. Returns `{ delivered: false, preview: true }` when SMTP is
/// not configured, after logging the message so the link is still reachable.
export async function sendMail({ to, subject, text, html }) {
  if (!isMailConfigured()) {
    // Never log the message body: password-reset emails contain a live token.
    console.warn(
      `[email] SMTP not configured; not sent (to ${to}, subject "${subject}"). ` +
        'Set MAILJET_API_KEY, MAILJET_SECRET_KEY and MAIL_FROM to enable delivery.'
    );
    return { delivered: false, preview: true };
  }

  await getTransporter().sendMail({
    from: fromAddress(),
    to,
    subject,
    text,
    html,
  });
  return { delivered: true, preview: false };
}

/// The password-reset message. `resetUrl` is the full link the user opens.
export async function sendPasswordResetEmail({ to, name, resetUrl, expiresInMinutes = 60 }) {
  const greeting = name ? `Hi ${name},` : 'Hi,';
  const text =
    `${greeting}\n\n` +
    `Someone asked to reset the password for your restaurant portal account.\n\n` +
    `Open this link to choose a new password:\n${resetUrl}\n\n` +
    `The link expires in ${expiresInMinutes} minutes. If you did not ask for this, ` +
    `you can ignore this email — your password will not change.`;

  const html =
    `<p>${greeting}</p>` +
    `<p>Someone asked to reset the password for your restaurant portal account.</p>` +
    `<p><a href="${resetUrl}">Choose a new password</a></p>` +
    `<p>The link expires in ${expiresInMinutes} minutes. If you did not ask for this, ` +
    `you can ignore this email — your password will not change.</p>`;

  return sendMail({
    to,
    subject: 'Reset your portal password',
    text,
    html,
  });
}
