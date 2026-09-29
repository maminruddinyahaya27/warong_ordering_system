import './globals.css';
import Navbar from '@/components/Navbar';
import SiteFooter from '@/components/SiteFooter';

export const metadata = {
  title: 'Warong — Menu & Price Portal',
  description: 'Maintain restaurant menu items, stations and prices.',
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>
        <Navbar />
        <main className="container">{children}</main>
        <SiteFooter />
      </body>
    </html>
  );
}
