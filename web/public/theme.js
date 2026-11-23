// Kept out of index.html: surcofi.com's CSP is script-src 'self' (no inline scripts).
(function () {
  try {
    var s = localStorage.getItem("surco-theme")
    var dark = s ? s === "dark" : matchMedia("(prefers-color-scheme: dark)").matches
    if (dark) document.documentElement.setAttribute("data-theme", "dark")
  } catch (e) {}
})()
