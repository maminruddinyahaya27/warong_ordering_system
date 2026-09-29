/// Site footer shown on every page, including the public customer order page.
export default function SiteFooter() {
  const year = new Date().getFullYear();
  return (
    <footer className="footer">
      © {year} Warong Ordering System by SenangBiz
    </footer>
  );
}
