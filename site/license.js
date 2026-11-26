// If Stripe's success URL includes ?key=, offer a link that opens the Mac app.
const key = new URLSearchParams(window.location.search).get('key');
const link = document.getElementById('open-app');
if (key && link && /^UC1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(key)) {
  link.href = `uncloud://license?key=${encodeURIComponent(key)}`;
  link.hidden = false;
}
