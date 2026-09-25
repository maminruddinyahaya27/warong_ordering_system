import ResetPasswordForm from '@/components/ResetPasswordForm';

export const dynamic = 'force-dynamic';

export default async function ResetPasswordPage({ searchParams }) {
  const resolved = (await searchParams) || {};
  const token = typeof resolved.token === 'string' ? resolved.token : '';

  return (
    <div className="login-wrap">
      <ResetPasswordForm token={token} />
    </div>
  );
}
