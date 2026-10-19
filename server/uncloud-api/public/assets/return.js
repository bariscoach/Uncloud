// Opens the Uncloud app from the hosted return pages. No inline scripts (CSP).
// Pages without data-app-url (the home page) do nothing. Pages with data-checkout-sync first
// ask the server to sync the Checkout Session (4 s limit; the webhook covers any failure),
// then open the app once.
(function () {
  'use strict';

  var main = document.querySelector('main[data-app-url]');
  if (!main) return;

  var baseURL = main.getAttribute('data-app-url');
  var button = document.querySelector('a[data-app-button]');
  var sessionPattern = /^cs_(test|live)_[A-Za-z0-9]+$/;
  var sessionId = new URLSearchParams(window.location.search).get('session_id') || '';
  var syncs = main.hasAttribute('data-checkout-sync') && sessionPattern.test(sessionId);

  var appURL = syncs ? baseURL + '?session_id=' + encodeURIComponent(sessionId) : baseURL;
  if (button) button.setAttribute('href', appURL);

  function openApp() {
    window.location.href = appURL;
  }

  if (!syncs || typeof fetch !== 'function') {
    openApp();
    return;
  }

  var controller = typeof AbortController === 'function' ? new AbortController() : null;
  var timer = setTimeout(function () {
    if (controller) controller.abort();
  }, 4000);

  fetch('/v1/checkout/sync', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ sessionId: sessionId }),
    credentials: 'omit',
    signal: controller ? controller.signal : undefined
  })
    .catch(function () { /* ignored: the webhook covers it */ })
    .then(function () {
      clearTimeout(timer);
      openApp();
    });
})();
