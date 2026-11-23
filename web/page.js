const themeBtn = document.querySelector("#themeToggle")
const nav = document.querySelector("#nav")
const burger = document.querySelector("#burger")
const links = document.querySelector("#navLinks")

function currentTheme() {
  return document.documentElement.getAttribute("data-theme") === "dark" ? "dark" : "light"
}

function applyTheme(theme) {
  if (theme === "dark") document.documentElement.setAttribute("data-theme", "dark")
  else document.documentElement.removeAttribute("data-theme")
  const dark = theme === "dark"
  themeBtn.setAttribute("aria-pressed", dark ? "true" : "false")
  themeBtn.setAttribute("aria-label", dark ? "Switch to day" : "Switch to dark mode")
}

applyTheme(currentTheme())

themeBtn.addEventListener("click", () => {
  const next = currentTheme() === "dark" ? "light" : "dark"
  try {
    localStorage.setItem("surco-theme", next)
  } catch (e) {}
  applyTheme(next)
})

addEventListener("scroll", () => {
  nav.classList.toggle("scrolled", scrollY > 8)
}, { passive: true })

burger.addEventListener("click", () => {
  const open = links.classList.toggle("open")
  burger.setAttribute("aria-expanded", open ? "true" : "false")
})

links.addEventListener("click", (event) => {
  if (event.target.closest("a")) {
    links.classList.remove("open")
    burger.setAttribute("aria-expanded", "false")
  }
})

// Footer "Copy link": clipboard needs a secure context, so say so if it is missing or refused.
const copyBtn = document.querySelector("#copyLink")
copyBtn?.addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(copyBtn.dataset.copy)
    copyBtn.textContent = "Link copied"
  } catch (e) {
    copyBtn.textContent = "Copy failed: surcofi.com"
  }
  setTimeout(() => (copyBtn.textContent = "Copy link"), 2000)
})
