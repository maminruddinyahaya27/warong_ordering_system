import './globals.css';
import Navbar from '@/components/Navbar';

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
        <footer className="footer">
          Warong Menu &amp; Price Portal · data stored in MongoDB
        </footer>
      </body>
    </html>
  );
}
