// Uncloud landing page: the two waitlist forms. No dependencies.

document.documentElement.classList.add("js");

const API_URL = "https://uncloud-api.vercel.app/v1/waitlist";
const JOINED_KEY = "uncloud.waitlist";
const TIMEOUT_MS = 10000;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

const COPY = {
  join: "Notify Me",
  sending: "Joining…",
  invalid: "Enter a valid email address.",
  rateLimited: "Too many tries. Try again in a few minutes.",
  network: "Couldn’t add you just now. Check your connection and try again.",
  success: "You’re on the list. We’ll email you when Uncloud is ready.",
  already: "You’re already on the list. See you at launch.",
};

function hasJoined() {
  try {
    return window.localStorage.getItem(JOINED_KEY) === "1";
  } catch (error) {
    return false;
  }
}

function rememberJoined() {
  try {
    window.localStorage.setItem(JOINED_KEY, "1");
  } catch (error) {
    // Storage can be blocked (private windows, cleared site data). The page still works.
  }
}

function setupJoin(block) {
  const form = block.querySelector("[data-waitlist-form]");
  const field = block.querySelector("[data-field]");
  const submit = block.querySelector("[data-submit]");
  const status = block.querySelector("[data-status]");
  const done = block.querySelector("[data-done]");
  const doneText = block.querySelector("[data-done-text]");
  const reset = block.querySelector("[data-reset]");
  const source = block.dataset.source === "landing-bottom" ? "landing-bottom" : "landing";

  function showMessage(message, { invalid = false } = {}) {
    status.textContent = message;
    status.classList.add("is-error");
    if (invalid) {
      field.setAttribute("aria-invalid", "true");
      field.setAttribute("aria-describedby", status.id);
      field.focus();
    }
  }

  function clearMessage() {
    status.textContent = "";
    status.classList.remove("is-error");
    field.removeAttribute("aria-invalid");
    field.removeAttribute("aria-describedby");
  }

  function showForm() {
    done.hidden = true;
    reset.hidden = true;
    form.hidden = false;
    clearMessage();
  }

  function showDone(message, { allowReset }) {
    form.hidden = true;
    status.textContent = "";
    doneText.textContent = message;
    reset.hidden = !allowReset;
    done.hidden = false;
    doneText.focus();
  }

  function setBusy(busy) {
    submit.disabled = busy;
    submit.textContent = busy ? COPY.sending : COPY.join;
  }

  async function join(email, website) {
    const controller = new AbortController();
    const timer = window.setTimeout(() => controller.abort(), TIMEOUT_MS);
    try {
      const response = await fetch(API_URL, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ email, website, source }),
        signal: controller.signal,
      });
      return response.status;
    } finally {
      window.clearTimeout(timer);
    }
  }

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const email = field.value.trim();

    if (email.length > 254 || !EMAIL_PATTERN.test(email)) {
      showMessage(COPY.invalid, { invalid: true });
      return;
    }

    clearMessage();
    setBusy(true);
    const website = form.elements.website ? form.elements.website.value : "";

    try {
      const status = await join(email, website);
      if (status === 200) {
        rememberJoined();
        showDone(COPY.success, { allowReset: false });
        return;
      }
      if (status === 400) {
        showMessage(COPY.invalid, { invalid: true });
      } else if (status === 429) {
        showMessage(COPY.rateLimited);
      } else {
        showMessage(COPY.network);
      }
    } catch (error) {
      showMessage(COPY.network);
    } finally {
      setBusy(false);
    }
  });

  field.addEventListener("input", () => {
    if (field.getAttribute("aria-invalid") === "true") {
      field.removeAttribute("aria-invalid");
      field.removeAttribute("aria-describedby");
      status.textContent = "";
      status.classList.remove("is-error");
    }
  });

  reset.addEventListener("click", () => {
    showForm();
    field.focus();
  });

  if (hasJoined()) {
    showDone(COPY.already, { allowReset: true });
  }
}

document.querySelectorAll("[data-join]").forEach(setupJoin);
