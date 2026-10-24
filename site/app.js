// Uncloud download page: fades sections and feature tiles in as they scroll into view.
// Without this script, or with reduced motion, every element stays visible.

const root = document.documentElement;
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

if (!reduceMotion.matches && "IntersectionObserver" in window) {
  // styles.css hides [data-reveal] only when this class is present.
  root.classList.add("js");

  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-in");
          observer.unobserve(entry.target);
        }
      }
    },
    { threshold: 0.12, rootMargin: "0px 0px -6% 0px" },
  );

  document.querySelectorAll("[data-reveal]").forEach((el) => observer.observe(el));
}
