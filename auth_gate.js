// auth_gate.js
(function() {
  if (typeof firebase === 'undefined') {
    console.warn('Firebase SDK not loaded.');
    return;
  }

  const auth = firebase.auth();

  auth.onAuthStateChanged(function(user) {
    const isLoginPage = window.location.pathname.endsWith('/login.html');

    if (!user) {
      if (!isLoginPage) {
        // Save current location to redirect back after login
        sessionStorage.setItem('redirect_url', window.location.href);
        window.location.href = '/login.html';
      }
    } else {
      // User is logged in, check email domain
      const email = user.email || '';
      const allowedDomains = window.ALLOWED_DOMAINS || [];
      
      if (allowedDomains.length > 0) {
        const isAllowed = allowedDomains.some(domain => email.endsWith(domain));
        if (!isAllowed) {
          alert('Access Denied: Your email address (' + email + ') is not authorized.');
          auth.signOut().then(function() {
            window.location.href = '/login.html';
          });
          return;
        }
      }

      if (isLoginPage) {
        const redirectUrl = sessionStorage.getItem('redirect_url') || '/index.html';
        sessionStorage.removeItem('redirect_url');
        window.location.href = redirectUrl;
      }
    }
  });
})();
