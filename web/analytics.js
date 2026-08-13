(function enablePrivacyFriendlyAnalytics() {
  window.va = window.va || function queueVercelAnalytics() {
    (window.vaq = window.vaq || []).push(arguments);
  };

  // Stripe checkout sessions and any future query parameters must never enter
  // analytics. Keeping the pathname still lets us count the thank-you page as
  // an approximate purchase conversion without exposing the purchase token.
  window.va('beforeSend', function redactSensitiveUrl(event) {
    try {
      var url = new URL(event.url);
      url.search = '';
      url.hash = '';
      event.url = url.toString();
    } catch (_) {
      return null;
    }
    return event;
  });

  var script = document.createElement('script');
  script.defer = true;
  script.src = '/_vercel/insights/script.js';
  document.head.appendChild(script);
})();
