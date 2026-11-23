import { decodeEventLog, getAddress, isAddress, parseEther } from "viem"
import {
  BASESCAN,
  FACTORY,
  FACTORY_ABI,
  FACTORY_V2_ABI,
  HAS_COLLECTIVE_SILO,
  HAS_METADATA_URI,
  IS_TEST_FACTORY,
  LAUNCH_FEE_WEI,
  MAX_CREATOR_BPS,
  MAX_FEE_BPS,
  MIN_FEE_BPS,
} from "./launcher-config.js"
import {
  estimateFirstBuyCoins,
  feeSplitBps,
  fmtTokenAmount,
  monogramInfo,
  sanitizeExternalUrl,
  sanitizeImageUri,
  shortAddr,
} from "./launcher-core.js"
import { connectWallet, friendlyError, getWallet, initWalletButton, onWallet, sendSimulatedWrite } from "./launcher-wallet.js"

initWalletButton("#connect")

const banner = document.querySelector("#test-banner")
const factoryLink = document.querySelector("#test-factory-link")
if (IS_TEST_FACTORY && banner) {
  banner.hidden = false
  if (factoryLink) {
    factoryLink.href = `${BASESCAN}/address/${FACTORY}`
    factoryLink.textContent = `Factory ${shortAddr(FACTORY)}`
  }
}

const form = document.querySelector("#launch-form")
const nameIn = document.querySelector("#f-name")
const symIn = document.querySelector("#f-symbol")
const fileIn = document.querySelector("#f-img-file")
const urlIn = document.querySelector("#f-img-url")
const uploadBox = document.querySelector("#img-upload-box")
const urlBox = document.querySelector("#img-url-box")
const toggleImgBtn = document.querySelector("#toggle-img-mode")
const imgErrorEl = document.querySelector("#img-error")
const clearImgBtn = document.querySelector("#clear-img-btn")
const previewWrap = document.querySelector("#img-preview-wrap")
const websiteIn = document.querySelector("#f-website")
const twitterIn = document.querySelector("#f-twitter")
const descIn = document.querySelector("#f-desc")
const firstBuyIn = document.querySelector("#f-first-buy")
const firstBuyNote = document.querySelector("#first-buy-preview")
const feePctIn = document.querySelector("#f-fee-pct")
const creatorPctIn = document.querySelector("#f-creator-pct")
const splitNote = document.querySelector("#fee-split-note")
const payoutIn = document.querySelector("#f-payout")
const submitBtn = document.querySelector("#launch-submit")
const statusEl = document.querySelector("#launch-status")

const launchFeeNote = document.querySelector("#launch-fee-note")
if (HAS_COLLECTIVE_SILO && launchFeeNote) launchFeeNote.hidden = false

const MAX_IMAGE_BYTES = 512 * 1024
const ALLOWED_IMAGE_TYPES = new Set(["image/png", "image/jpeg", "image/webp"])

let useUrlMode = false
let localPreviewUrl = ""
let imageError = ""
let busy = false

function setImageError(msg) {
  imageError = msg
  if (imgErrorEl) {
    imgErrorEl.textContent = msg
    imgErrorEl.hidden = !msg
  }
  if (submitBtn && !busy) submitBtn.disabled = Boolean(msg)
}

function fmtFileSize(bytes) {
  if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(2)} MB`
  return `${Math.ceil(bytes / 1024)} KB`
}

function setStatus(msg, cls = "") {
  statusEl.textContent = msg
  statusEl.className = `l-status ${cls}`.trim()
}

function updatePreview() {
  const sym = symIn.value.trim()
  const mono = monogramInfo(payoutIn.value.trim() || sym, sym)
  previewWrap.textContent = ""
  previewWrap.style.background = mono.bg
  previewWrap.style.color = mono.fg

  const src = useUrlMode ? sanitizeImageUri(urlIn.value) : localPreviewUrl
  if (src) {
    const img = document.createElement("img")
    img.src = src
    img.alt = "Coin preview"
    img.addEventListener("error", () => {
      img.remove()
      previewWrap.textContent = mono.label
    })
    previewWrap.appendChild(img)
  } else {
    previewWrap.textContent = mono.label
  }
}

function parseFeeBps() {
  return Math.round((Number(feePctIn.value) || 0) * 100)
}

function parseCreatorBps() {
  return Math.round((Number(creatorPctIn.value) || 0) * 100)
}

function updateMathPreviews() {
  const feeBps = Math.max(MIN_FEE_BPS, Math.min(MAX_FEE_BPS, parseFeeBps()))
  const { platformBps, creatorBps, pintoBps } = feeSplitBps(parseCreatorBps())
  splitNote.textContent = `Fee split: ${platformBps / 100}% platform · ${creatorBps / 100}% creator · ${pintoBps / 100}% Pinto Silo`

  const rawEth = firstBuyIn.value.trim()
  if (!rawEth) {
    firstBuyNote.textContent = "Optional. Runs inside the launch tx at the plain fee before the 10-minute sniper toll starts."
    return
  }
  try {
    const wei = parseEther(rawEth)
    if (wei <= 0n) throw new Error()
    const est = estimateFirstBuyCoins(wei, feeBps)
    const pct = (Number(est) / 1e27) * 100
    const sym = symIn.value.trim().toUpperCase() || "coins"
    firstBuyNote.textContent = `Est. first buy: ~${fmtTokenAmount(String(est))} ${sym} (~${pct.toFixed(2)}% of supply).`
  } catch {
    firstBuyNote.textContent = "Enter a valid ETH amount (e.g. 0.01) or leave blank."
  }
}

toggleImgBtn?.addEventListener("click", () => {
  useUrlMode = !useUrlMode
  uploadBox.hidden = useUrlMode
  urlBox.hidden = !useUrlMode
  toggleImgBtn.textContent = useUrlMode ? "Or upload an image file instead" : "Or paste an image URL instead"
  if (useUrlMode) {
    setImageError("")
  } else {
    validateSelectedFile()
  }
  updatePreview()
})

function validateSelectedFile() {
  if (localPreviewUrl) URL.revokeObjectURL(localPreviewUrl)
  localPreviewUrl = ""
  const file = fileIn?.files?.[0]
  if (clearImgBtn) clearImgBtn.hidden = !file
  if (!file) {
    setImageError("")
    return
  }
  if (file.type && !ALLOWED_IMAGE_TYPES.has(file.type)) {
    setImageError(`Unsupported image format (${file.type}). Upload a PNG, JPEG, or WebP file, or remove the image to continue.`)
    return
  }
  if (file.size > MAX_IMAGE_BYTES) {
    setImageError(`Image is too large (${fmtFileSize(file.size)} — max 512 KB). Choose a smaller image or click "Remove image" to launch without one.`)
    return
  }
  setImageError("")
  setStatus("")
  localPreviewUrl = URL.createObjectURL(file)
}

fileIn?.addEventListener("change", () => {
  validateSelectedFile()
  updatePreview()
})

clearImgBtn?.addEventListener("click", () => {
  if (fileIn) fileIn.value = ""
  validateSelectedFile()
  updatePreview()
})

urlIn?.addEventListener("input", updatePreview)
symIn?.addEventListener("input", () => {
  updatePreview()
  updateMathPreviews()
})
firstBuyIn?.addEventListener("input", updateMathPreviews)
feePctIn?.addEventListener("input", updateMathPreviews)
creatorPctIn?.addEventListener("input", updateMathPreviews)

onWallet(({ account }) => {
  if (account && !payoutIn.value.trim()) {
    payoutIn.placeholder = account
  }
})

updatePreview()
updateMathPreviews()

async function uploadImageFile(file) {
  setStatus("Uploading image…")
  const res = await fetch("/api/launcher/image", {
    method: "POST",
    headers: { "content-type": file.type || "application/octet-stream" },
    body: file,
  })
  const data = await res.json().catch(() => ({}))
  if (!res.ok || !data.url) {
    throw new Error(data.error || `Image upload failed (${res.status}).`)
  }
  return data.url
}

async function uploadMetadataDoc(payload) {
  setStatus("Saving token metadata…")
  const res = await fetch("/api/launcher/meta", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  })
  const data = await res.json().catch(() => ({}))
  if (!res.ok || !data.url) {
    throw new Error(data.error || `Metadata upload failed (${res.status}).`)
  }
  return { key: data.key, url: data.url }
}

form?.addEventListener("submit", async (e) => {
  e.preventDefault()
  if (busy) return
  try {
    let { account } = getWallet()
    if (!account) account = await connectWallet()

    const name = nameIn.value.trim()
    const symbol = symIn.value.trim()
    if (!name || !symbol) {
      setStatus("Enter both a coin name and symbol.", "err")
      return
    }

    const rawWebsite = websiteIn?.value.trim() || ""
    const website = rawWebsite ? sanitizeExternalUrl(rawWebsite) : ""
    if (rawWebsite && !website) {
      setStatus("Website URL must start with https://", "err")
      return
    }
    const rawTwitter = twitterIn?.value.trim() || ""
    const twitter = rawTwitter ? sanitizeExternalUrl(rawTwitter) : ""
    if (rawTwitter && !twitter) {
      setStatus("X / Twitter URL must start with https://", "err")
      return
    }
    const description = descIn?.value.trim().slice(0, 280) || ""

    const feeBps = parseFeeBps()
    if (feeBps < MIN_FEE_BPS || feeBps > MAX_FEE_BPS) {
      setStatus("Trade fee must be between 0.30% and 3.00%.", "err")
      return
    }
    const creatorBps = parseCreatorBps()
    if (creatorBps < 0 || creatorBps > MAX_CREATOR_BPS) {
      setStatus("Creator share must be between 0% and 20%.", "err")
      return
    }

    const payoutRaw = payoutIn.value.trim() || account
    if (!isAddress(payoutRaw)) {
      setStatus("Creator payout must be a valid 0x address.", "err")
      return
    }
    const creatorPayout = getAddress(payoutRaw)
    if (creatorPayout.toLowerCase() === FACTORY.toLowerCase()) {
      setStatus("Creator payout cannot be the factory address.", "err")
      return
    }

    let firstBuyWei = 0n
    const rawEth = firstBuyIn.value.trim()
    if (rawEth) {
      try {
        firstBuyWei = parseEther(rawEth)
        if (firstBuyWei < 0n) throw new Error()
      } catch {
        setStatus("Enter a valid ETH amount for first buy.", "err")
        return
      }
    }

    if (!useUrlMode) {
      validateSelectedFile()
      if (imageError) {
        setStatus(imageError, "err")
        imgErrorEl?.scrollIntoView({ behavior: "smooth", block: "center" })
        return
      }
    }

    let imageURI = ""
    if (useUrlMode) {
      const rawUrl = urlIn.value.trim()
      if (rawUrl) {
        const clean = sanitizeImageUri(rawUrl)
        if (!clean) {
          setStatus("Image URL must start with https:// or ipfs://.", "err")
          return
        }
        imageURI = rawUrl
      }
    }

    const modeRadio = form.querySelector('input[name="mode"]:checked')
    const mode = Number(modeRadio?.value ?? 1)

    busy = true
    submitBtn.disabled = true

    if (!useUrlMode && fileIn.files?.[0]) {
      imageURI = await uploadImageFile(fileIn.files[0])
    }

    let metadataURI = ""
    let metaKey = ""
    if (website || twitter || description || imageURI) {
      const meta = await uploadMetadataDoc({ name, symbol, description, image: imageURI, website, twitter })
      metadataURI = meta.url
      metaKey = meta.key
    }

    const launchAbi = HAS_METADATA_URI ? FACTORY_V2_ABI : FACTORY_ABI
    const launchArgs = HAS_METADATA_URI
      ? [{ name, symbol, imageURI, metadataURI, mode, feeBps, creatorBps, creatorPayout }]
      : [{ name, symbol, imageURI, mode, feeBps, creatorBps, creatorPayout }]

    const totalValueWei = firstBuyWei + (HAS_COLLECTIVE_SILO ? LAUNCH_FEE_WEI : 0n)

    const { receipt } = await sendSimulatedWrite(
      {
        address: FACTORY,
        abi: launchAbi,
        functionName: "launch",
        args: launchArgs,
        value: totalValueWei,
      },
      (step) => setStatus(step),
    )

    let launchedCoin = ""
    for (const log of receipt.logs) {
      if (log.address.toLowerCase() !== FACTORY.toLowerCase()) continue
      try {
        const ev = decodeEventLog({ abi: launchAbi, topics: log.topics, data: log.data })
        if (ev.eventName === "Launched") {
          launchedCoin = ev.args.coin
          break
        }
      } catch {}
    }

    if (launchedCoin && !HAS_METADATA_URI && metaKey) {
      try {
        await fetch("/api/launcher/coin-meta", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ coin: launchedCoin, key: metaKey }),
        })
      } catch {}
    }

    if (launchedCoin) {
      setStatus("Launched! Opening coin page…", "ok")
      window.location.href = `/coin?a=${encodeURIComponent(launchedCoin)}`
    } else {
      setStatus("Launched on Base! Check /coins.", "ok")
    }
  } catch (err) {
    setStatus(
      friendlyError(err, {
        BadFee: "Trade fee must be between 0.30% and 3.00%.",
        BadCreatorBps: "Creator share cannot exceed 20%.",
        EmptyName: "Name and symbol are required.",
        BadPayout: "Invalid creator payout address.",
        InsufficientLaunchFee: "Launch requires the 0.0001 ETH Collective Silo fee.",
      }),
      "err",
    )
  } finally {
    busy = false
    submitBtn.disabled = Boolean(imageError)
  }
})
