addEventListener('DOMContentLoaded', () => {
  for (const card of document.querySelectorAll('.use-card[data-kind]')) card.querySelector('.use-head').prepend(window.fizzKinds.badge(card.dataset.kind));
  for (const signal of document.querySelectorAll('[data-signal]')) signal.prepend(window.fizzKinds.badge(signal.dataset.signal));
});
// Mobile menu: toggle, close after choosing a link or pressing Escape.
const navToggle = document.getElementById('nav-toggle');
const navLinks = document.getElementById('nav-links');
const setMenu = (open) => { navLinks.classList.toggle('open', open); navToggle.setAttribute('aria-expanded', String(open)); };
navToggle.addEventListener('click', () => setMenu(!navLinks.classList.contains('open')));
navLinks.addEventListener('click', (event) => { if (event.target.closest('a')) setMenu(false); });
addEventListener('keydown', (event) => { if (event.key === 'Escape' && navLinks.classList.contains('open')) { setMenu(false); navToggle.focus(); } });
// Waitlist links scroll smoothly to the hero copy, then focus the field without jumping.
for (const link of document.querySelectorAll('a[href="#join"]')) {
  link.addEventListener('click', () => setTimeout(() => document.getElementById('waitlist-email').focus({ preventScroll: true }), 500));
}
// Highlight the menu item for the section in view.
const navFor = new Map([...navLinks.querySelectorAll('a[href^="#"]')].map((a) => [a.getAttribute('href').slice(1), a]));
const sectionObserver = new IntersectionObserver((entries) => {
  for (const entry of entries) navFor.get(entry.target.id)?.setAttribute('aria-current', String(entry.isIntersecting));
}, { rootMargin: '-45% 0px -50% 0px' });
for (const id of navFor.keys()) { const section = document.getElementById(id); if (section?.tagName === 'SECTION') sectionObserver.observe(section); }

const waitlist = document.getElementById('waitlist');
const status = document.getElementById('waitlist-status');
waitlist.addEventListener('submit', async (event) => {
  event.preventDefault();
  const input = document.getElementById('waitlist-email');
  const button = waitlist.querySelector('button');
  status.classList.remove('error');
  if (!input.checkValidity()) {
    status.classList.add('error');
    status.textContent = 'Enter a valid email address.';
    input.focus();
    return;
  }
  button.disabled = true;
  status.textContent = 'Adding you…';
  try {
    const response = await fetch('/api/waitlist', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email: input.value.trim() }) });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(result.error?.message || 'Something went wrong. Try again.');
    waitlist.reset();
    status.textContent = "You're on the list. We'll email you when your invite is ready.";
  } catch (error) {
    status.classList.add('error');
    status.textContent = error instanceof TypeError ? 'Could not reach Fizzlayer. Check your connection and try again.' : error.message;
  } finally {
    button.disabled = false;
  }
});

const business = document.getElementById('business-form');
const businessStatus = document.getElementById('business-status');
business.addEventListener('submit', async (event) => {
  event.preventDefault();
  const email = document.getElementById('business-email');
  const company = document.getElementById('business-company');
  const button = business.querySelector('button');
  businessStatus.classList.remove('error');
  const invalid = !email.checkValidity() ? [email, 'Enter a valid work email.'] : !company.value.trim() ? [company, 'Enter your company name.'] : null;
  if (invalid) {
    businessStatus.classList.add('error');
    businessStatus.textContent = invalid[1];
    invalid[0].focus();
    return;
  }
  button.disabled = true;
  businessStatus.textContent = 'Sending…';
  try {
    const response = await fetch('/api/waitlist', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ kind: 'business', email: email.value.trim(), company: company.value.trim(), interest: document.getElementById('business-interest').value.trim() }),
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(result.error?.message || 'Something went wrong. Try again.');
    businessStatus.textContent = `Thanks. We'll be in touch at ${email.value.trim().toLowerCase()}.`;
    business.reset();
  } catch (error) {
    businessStatus.classList.add('error');
    businessStatus.textContent = error instanceof TypeError ? 'Could not reach Fizzlayer. Check your connection and try again.' : error.message;
  } finally {
    button.disabled = false;
  }
});
