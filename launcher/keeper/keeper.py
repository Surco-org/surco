#!/usr/bin/python3
"""Surco Launcher keeper. Periodically discovers every vault the factory launched and
turns it over: seed() any Pinto sent to it, convert() its fees (split first), and at peg buyback() (Burn) or
claim() (Redeem). Subsidized: pays gas, only converting a vault holding >= 0.0005 WETH of fees. Optional Telegram
alerts on crash, a vault failing 3 runs in a row, or a low wallet. Uses stdlib plus eth_account (imported lazily to sign).
"""
import datetime
import http.client
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

RPC = os.environ.get("RPC_URL", "https://base-rpc.publicnode.com")  # mainnet.base.org 429s on any eth_getLogs
STATE = "./state.json"
TIP = 1_000_000  # 0.001 gwei
BACKOFF = (2, 4, 8)
RATE_LIMIT_CODES = (-32011, -32005)
CHUNK, MIN_CHUNK = 20_000, 1_000
CONVERT_GAP_S, MAX_CONVERTS, BUYBACK_TRIES = 600, 5, 3
LOW_WALLET_FLOOR = 5 * 10**14
L1_RESERVE = 10**10  # op-geth also requires the L1 data fee
ZERO = "0x" + "00" * 20
_urlopen = urllib.request.urlopen

SEL = {"split": "0xf7654176", "convert": "0x91bbdcc7", "seed": "0x7d94792a", "claim": "0x4e71d92d",
       "buyback": "0x79a9fa1c", "pendingPintoWeth": "0x49bc3298", "balanceOf": "0x70a08231", "abovePeg": "0x2a27c499",
       "plant": "0x779b3c5c", "distribute": "0xabc0eebd", "dayPinto": "0x0a28ec9a", "dayTotalWeight": "0x251375ec",
       "coinDayPaidPinto": "0x7bef762d", "currentDay": "0x5c9302c9", "coinWeightAt": "0x06db52c3",
       "mergeYieldStems": "0xc99ed56e", "yieldStems": "0xabeab36f"}
ERR = {"0x175c1aea": "NothingPending", "0x1078b533": "ZeroOut", "0x7dd37f70": "Slippage",
       "0x0482f87a": "TickDrift", "0x82bfe72c": "ZeroBatch", "0x0f2e5b6c": "Locked",
       "0x0c092543": "DayNotFinished", "0x8c787063": "BadDaysOrder", "0x6c3ce450": "UnknownCoin",
       "0x86f8a5c1": "TollActive", "0xe9dbb221": "NoEma", "0xd964f528": "PartialFill",
       "0xea61c7da": "MergeGas", "0xe55cd0a7": "ShortMerge"}
SKIP = {"NothingPending", "ZeroOut", "ZeroBatch", "TollActive", "NoEma", "DayNotFinished"}
RETRY = {"Slippage", "TickDrift", "Locked"}
LAUNCHED_TOPIC = "0x3f551805ad708fca005c125e66bd2fffa2fc8c74cbe058dabb252c5280e2e3ca"
WETH = "0x4200000000000000000000000000000000000006"
PINTO = "0xb170000aeefa790fa61d6e837d1035906839a3c8"
DIAMOND = "0xd1a0d188e861ed9d15773a2f3574a2e94134ba8f"
MAX_CONVERT_WETH = 5 * 10**16
MIN_CONVERT_WETH = 5 * 10**14  # converting less than 0.0005 WETH is not economical relative to gas
MAX_BUYBACK_PINTO = 2_000 * 10**6
MIN_DAY_ENTITLED = 10_000  # 0.01 Pinto, mirrors CollectiveSilo.MIN_DAY_ENTITLED
MIN_DISTRIBUTE_PINTO = 500_000  # 0.50 Pinto floor so CollectiveSilo.distribute() doesn't burn gas on dust
MAX_DISTRIBUTES = 5
COLLECTIVE_LOOKBACK_DAYS = 14
PREFIX = "[LAUNCHER keeper] "


def plan(mode, weth, pending, pinto, above_peg):
    """Actions for one vault, in order. weth >= pending always and convert() splits first, so the vault's whole WETH
    balance is the fee pile; under MIN_CONVERT_WETH it waits (creator and platform shares wait with it)."""
    acts = []
    if pinto > 0:
        acts.append("seed")
    if weth >= MIN_CONVERT_WETH:
        acts.append("convert")
    if above_peg:
        acts.append("buyback" if mode == 1 else "claim")
    return acts


def plan_collective(weth, pinto, above_peg):
    """Actions for the CollectiveSilo before per-coin distributions."""
    acts = []
    if pinto > 0:
        acts.append("seed")
    if weth >= MIN_CONVERT_WETH:
        acts.append("convert")
    if above_peg:
        acts.append("plant")
    return acts


def uword(n):
    return f"{n:064x}"


def encode_distribute(coin, days_list, max_pinto):
    """ABI-encodes CollectiveSilo.distribute(address coin, uint32[] daysList, uint256 maxPinto)."""
    return (SEL["distribute"] + word(coin) + uword(96) + uword(max_pinto) + uword(len(days_list))
            + "".join(uword(d) for d in days_list))


def revert_name(data):
    return ERR.get((data or "")[:10].lower())


def classify(data):
    name = revert_name(data)
    return "skip" if name in SKIP else "retry" if name in RETRY else "fail"


def parse_launched(log):
    coin = "0x" + log["topics"][1][-40:].lower()
    data = log["data"][2:]
    return coin, "0x" + data[24:64].lower(), int(data[64:128], 16)


def alerts(state, fails, crashed, low_wallet, today):
    """(new alert map, messages). A reason alerts at most once per day; one ✅ when it clears."""
    prev = dict(state.get("alerts", {}))
    now = {}
    if crashed:
        now["crash"] = f"run crashed: {crashed}"
    if low_wallet:
        now["wallet"] = "keeper wallet is low, top it up"
    for vault, n in fails.items():
        if n >= 3:
            now[f"vault:{vault}"] = f"vault {vault} failed {n} runs in a row"
    msgs, out = [], {}
    for reason, text in now.items():
        out[reason] = today
        if prev.get(reason) != today:
            msgs.append(f"⚠ {text}")
    for reason in prev:
        if reason not in now:
            msgs.append(f"✅ {reason} cleared")
    return out, msgs


# ---- chain I/O ------------------------------------------------------------------------------------------------------

class RpcError(Exception):
    def __init__(self, code, message, data=None):
        super().__init__(f"{code} {message}")
        self.code, self.message, self.data = code, message, data if isinstance(data, str) else None


def rpc(method, params):
    """JSON-RPC result. Rate limits (HTTP 429, -32011, -32005) back off 2, 4, 8 s, then raise RpcError."""
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    for attempt in range(len(BACKOFF) + 1):
        req = urllib.request.Request(RPC, body, {"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"})
        try:
            with _urlopen(req, timeout=30) as r:
                resp = json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < len(BACKOFF):
                time.sleep(BACKOFF[attempt])
                continue
            raise RpcError(e.code, f"HTTP {e.code}") from None
        except (urllib.error.URLError, OSError, ValueError, http.client.HTTPException) as e:  # incl. non-JSON bodies
            if attempt < len(BACKOFF):
                time.sleep(BACKOFF[attempt])
                continue
            raise RpcError(None, type(e).__name__) from None
        if "error" in resp:
            err = resp["error"]
            if err.get("code") in RATE_LIMIT_CODES and attempt < len(BACKOFF):
                time.sleep(BACKOFF[attempt])
                continue
            raise RpcError(err.get("code"), err.get("message"), err.get("data"))
        if "result" not in resp:
            raise RpcError(None, "no result")
        return resp["result"]


def word(addr):
    return addr[2:].lower().rjust(64, "0")


def call(to, data):
    return int(rpc("eth_call", [{"to": to, "data": data}, "latest"]), 16)


def estimate(sender, to, data):
    return int(rpc("eth_estimateGas", [{"from": sender, "to": to, "data": data}]), 16)


def sign(tx, key):
    from eth_account import Account  # lazy: 37 MB, only a real run needs it
    from eth_utils import to_checksum_address  # ships with eth_account; 0.11.3 refuses a lowercase `to`
    signed = Account.sign_transaction({**tx, "to": to_checksum_address(tx["to"])}, key)
    raw = (getattr(signed, "raw_transaction", None) or signed.rawTransaction).hex()  # VM eth_account 0.11.3 = camelCase
    return raw if raw.startswith("0x") else "0x" + raw


def send(key, sender, nonce, to, data, gas, max_fee):
    """(tx hash, status, gas used, wei spent). Status -1 = no receipt within 120 s."""
    tx = {"to": to, "data": data, "value": 0, "gas": gas, "maxFeePerGas": max_fee, "maxPriorityFeePerGas": TIP,
          "nonce": nonce, "chainId": 8453, "type": 2}
    h = rpc("eth_sendRawTransaction", [sign(tx, key)])
    for _ in range(60):
        time.sleep(2)
        try:
            r = rpc("eth_getTransactionReceipt", [h])
        except RpcError:
            continue  # the tx is out; a failed poll must not lose it
        if r:
            used = int(r["gasUsed"], 16)
            cost = used * int(r["effectiveGasPrice"], 16) + int(r.get("l1Fee") or "0x0", 16)
            return h, int(r["status"], 16), used, cost
    return h, -1, 0, gas * max_fee


def load_state(path, factory_block):
    try:
        with open(path) as f:
            s = json.load(f)
        if isinstance(s, dict) and {"last_block", "vaults", "fails", "alerts"} <= s.keys():
            return s
    except (OSError, ValueError):
        pass
    return {"last_block": factory_block - 1, "vaults": [], "fails": {}, "alerts": {}}


def save_state(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, path)


def discover(state, factory, head, path):
    """Appends every vault launched up to `head`; saves after each chunk so a crash never rescans."""
    known = {v["vault"] for v in state["vaults"]}
    start, chunk = state["last_block"] + 1, CHUNK
    while start <= head:
        end = min(start + chunk - 1, head)
        try:
            logs = rpc("eth_getLogs", [{"address": factory, "topics": [LAUNCHED_TOPIC],
                                        "fromBlock": hex(start), "toBlock": hex(end)}])
        except RpcError:
            if chunk > MIN_CHUNK:
                chunk //= 2
                continue
            raise
        for log in logs:
            coin, vault, mode = parse_launched(log)
            if vault not in known:
                known.add(vault)
                state["vaults"].append({"vault": vault, "coin": coin, "mode": mode})
                print(f"new vault {vault} coin {coin} mode {mode}", flush=True)
        state["last_block"] = end
        save_state(path, state)
        start = end + 1


def telegram(text, chat_id):
    """True when Telegram accepted it. Never raises, never prints the token."""
    try:
        with open(os.path.join(os.environ.get("CREDENTIALS_DIRECTORY", ""), "telegram_token")) as f:
            token = f.read().strip()
        data = urllib.parse.urlencode({"chat_id": chat_id, "text": PREFIX + text}).encode()
        with urllib.request.urlopen(f"https://api.telegram.org/bot{token}/sendMessage", data, timeout=20) as r:
            return r.status == 200
    except Exception as e:
        print(f"telegram send failed: {type(e).__name__}", file=sys.stderr)
        return False


# ---- the daily run --------------------------------------------------------------------------------------------------

def turn(v, peg, ctx):
    """Runs one vault's actions. True when every action ended in success or a skip, None if the wallet ran low."""
    vault, mode = v["vault"], v["mode"]
    weth = call(WETH, SEL["balanceOf"] + word(vault))
    pending = call(vault, SEL["pendingPintoWeth"])
    pinto = call(PINTO, SEL["balanceOf"] + word(vault))
    for act in plan(mode, weth, pending, pinto, peg):
        max_pinto, tries, converts = MAX_BUYBACK_PINTO, 0, 0
        while True:
            data = SEL[act] + (f"{max_pinto:064x}" if act == "buyback" else "")
            try:
                g = estimate(ctx["sender"], vault, data)
            except RpcError as e:
                kind, name = classify(e.data), revert_name(e.data) or e.message
                print(f"{vault} {act} {'DRY ' if ctx['dry'] else ''}revert {name} -> {kind}", flush=True)
                if act == "buyback" and kind == "retry" and tries < BUYBACK_TRIES - 1:
                    max_pinto, tries = max_pinto // 2, tries + 1
                    continue
                if kind == "skip":
                    break
                return False
            if ctx["dry"]:
                print(f"DRY {vault} {act} est={g}", flush=True)
                break
            gas = g * 13 // 10
            need = gas * ctx["max_fee"] + L1_RESERVE
            if ctx["balance"] < need:
                ctx["low"] = True
                print(f"{vault} {act} skipped: wallet {ctx['balance']} < {need}; no more sends this run", flush=True)
                return None  # the wallet, not the vault, is at fault: leave its streak alone
            try:
                h, status, used, cost = send(ctx["key"], ctx["sender"], ctx["nonce"], vault, data, gas, ctx["max_fee"])
            except RpcError:
                # the tx may be out (send timed out, "already known"): take the node's nonce, not ours
                ctx["nonce"] = int(rpc("eth_getTransactionCount", [ctx["sender"], "pending"]), 16)
                raise
            ctx["nonce"] += 1
            ctx["spent"] += cost
            ctx["balance"] -= cost
            print(f"{vault} {act} {h} status={status} gas={used}", flush=True)
            if status != 1:
                return False
            converts += act == "convert"
            # ponytail: sleeping in-run caps a run at ~2h (TimeoutStartSec); fine until vaults take >0.05 WETH/day
            if act == "convert" and converts < MAX_CONVERTS and call(vault, SEL["pendingPintoWeth"]) >= MIN_CONVERT_WETH:
                time.sleep(CONVERT_GAP_S)
                continue
            break
    return True


def _exec_tx(target, label, data, ctx):
    """Estimates, checks wallet balance, and sends one tx. Returns ('ok'|'skip'|'retry'|'fail'|'low')."""
    try:
        g = estimate(ctx["sender"], target, data)
    except RpcError as e:
        kind, name = classify(e.data), revert_name(e.data) or e.message
        print(f"{target} {label} {'DRY ' if ctx['dry'] else ''}revert {name} -> {kind}", flush=True)
        return kind
    if ctx["dry"]:
        print(f"DRY {target} {label} est={g}", flush=True)
        return "ok"
    gas = g * 13 // 10
    need = gas * ctx["max_fee"] + L1_RESERVE
    if ctx["balance"] < need:
        ctx["low"] = True
        print(f"{target} {label} skipped: wallet {ctx['balance']} < {need}; no more sends this run", flush=True)
        return "low"
    try:
        h, status, used, cost = send(ctx["key"], ctx["sender"], ctx["nonce"], target, data, gas, ctx["max_fee"])
    except RpcError:
        ctx["nonce"] = int(rpc("eth_getTransactionCount", [ctx["sender"], "pending"]), 16)
        raise
    ctx["nonce"] += 1
    ctx["spent"] += cost
    ctx["balance"] -= cost
    print(f"{target} {label} {h} status={status} gas={used}", flush=True)
    return "ok" if status == 1 else "fail"


def turn_collective(collective, ve_chirp, coins, peg, ctx, state=None):
    """Turns over CollectiveSilo: seed(), convert() launch-fee WETH, plant() at peg, mergeYieldStems() if >3 stems,
    and distribute() backed coins for completed past days (works both above and below peg)."""
    weth = call(WETH, SEL["balanceOf"] + word(collective))
    pinto = call(PINTO, SEL["balanceOf"] + word(collective))
    ok = True
    for act in plan_collective(weth, pinto, peg):
        if act == "plant" and call(collective, SEL["plant"]) == 0:
            continue  # nothing plantable right now; skip gas
        converts = 0
        while True:
            res = _exec_tx(collective, act, SEL[act], ctx)
            if res == "low":
                return None
            if res == "skip":
                break
            if res != "ok":
                ok = False  # isolate failure (e.g. convert slippage) so plant()/distribute() still run
                break
            converts += act == "convert"
            if (act == "convert" and not ctx["dry"] and converts < MAX_CONVERTS
                    and call(WETH, SEL["balanceOf"] + word(collective)) >= MIN_CONVERT_WETH):
                time.sleep(CONVERT_GAP_S)
                continue
            break

    # Best-effort fallback merge if >3 yield stems accumulated.
    try:
        raw = rpc("eth_call", [{"to": collective, "data": SEL["yieldStems"]}, "latest"])
        if isinstance(raw, str) and len(raw) >= 130 and int(raw[66:130], 16) > 3:
            res = _exec_tx(collective, "mergeYieldStems", SEL["mergeYieldStems"], ctx)
            if res == "low":
                return None
    except (RpcError, ValueError):
        pass

    if not coins:
        return ok

    today = call(ve_chirp, SEL["currentDay"])
    saved_day = state.get("collective_day", 0) if isinstance(state, dict) else 0
    default_start = max(1, today - COLLECTIVE_LOOKBACK_DAYS)
    start_day = saved_day if 0 < saved_day < today else default_start
    active_days = []
    for d in range(start_day, today):
        dp = call(collective, SEL["dayPinto"] + uword(d))
        if dp == 0:
            continue
        tw = call(collective, SEL["dayTotalWeight"] + uword(d))
        if tw > 0:
            active_days.append((d, dp, tw))
    if not active_days:
        if isinstance(state, dict) and not ctx["dry"] and today > 0:
            state["collective_day"] = today
        return ok

    earliest_unsettled = today
    for coin in coins:
        for _ in range(MAX_DISTRIBUTES):
            pending_days, pending_pinto, has_partial = [], 0, False
            for d, dp, tw in active_days:
                cw = call(ve_chirp, SEL["coinWeightAt"] + word(coin) + uword(d))
                if cw == 0:
                    continue
                entitled = dp * cw // tw
                if entitled < MIN_DAY_ENTITLED:
                    continue
                paid = call(collective, SEL["coinDayPaidPinto"] + word(coin) + uword(d))
                if entitled > paid:
                    pending_days.append(d)
                    pending_pinto += entitled - paid
                    if paid > 0:
                        has_partial = True
            if not pending_days:
                break
            if pending_pinto < MIN_DISTRIBUTE_PINTO and not has_partial:
                earliest_unsettled = min(earliest_unsettled, pending_days[0])
                break
            max_pinto, tries, sent_ok = min(pending_pinto, MAX_BUYBACK_PINTO), 0, False
            while True:
                res = _exec_tx(collective, f"distribute:{coin[:10]}", encode_distribute(coin, pending_days, max_pinto), ctx)
                if res == "low":
                    return None
                if res == "retry" and tries < BUYBACK_TRIES - 1:
                    max_pinto, tries = max_pinto // 2, tries + 1
                    if max_pinto < MIN_DAY_ENTITLED:
                        break
                    continue
                if res == "ok":
                    sent_ok = True
                elif res != "skip":
                    ok = False
                break
            if not sent_ok or ctx["dry"] or pending_pinto <= max_pinto:
                if not sent_ok or ctx["dry"]:
                    earliest_unsettled = min(earliest_unsettled, pending_days[0])
                break
        else:
            if pending_days:
                earliest_unsettled = min(earliest_unsettled, pending_days[0])

    if isinstance(state, dict) and not ctx["dry"]:
        state["collective_day"] = earliest_unsettled
    return ok


def run(env):
    global RPC
    RPC = env.get("RPC_URL", RPC)
    factory, path, dry = env["FACTORY"].lower(), env.get("STATE", STATE), env.get("DRY_RUN") == "1"
    collective = (env.get("COLLECTIVE_SILO") or "").strip().lower()
    ve_chirp = (env.get("VE_CHIRP") or "").strip().lower()
    state = load_state(path, int(env["FACTORY_BLOCK"]))
    ctx = {"dry": dry, "key": env.get("PRIVATE_KEY"), "spent": 0, "low": False}
    if dry:
        ctx["sender"] = env.get("SENDER", ZERO).lower()
    else:
        from eth_account import Account
        ctx["sender"] = Account.from_key(ctx["key"]).address
    crashed = None
    try:
        try:
            discover(state, factory, int(rpc("eth_blockNumber", []), 16), path)
        except RpcError as e:  # known vaults still get turned; the alert still fires
            crashed = f"discovery failed: {e}"
            print(crashed, flush=True)
        peg = call(DIAMOND, SEL["abovePeg"]) != 0
        base = int(rpc("eth_getBlockByNumber", ["latest", False])["baseFeePerGas"], 16)
        ctx["max_fee"] = 2 * base + TIP
        ctx["balance"] = int(rpc("eth_getBalance", [ctx["sender"], "latest"]), 16)
        ctx["nonce"] = int(rpc("eth_getTransactionCount", [ctx["sender"], "pending"]), 16)
        print(f"run: {len(state['vaults'])} vaults, abovePeg={peg}, balance={ctx['balance']}, dry={dry}", flush=True)
        for v in state["vaults"]:
            if ctx["low"]:
                break
            try:
                ok = turn(v, peg, ctx)
            except RpcError as e:
                print(f"{v['vault']} rpc error {e}", flush=True)
                ok = False
            if not dry and ok is not None:
                state["fails"][v["vault"]] = 0 if ok else state["fails"].get(v["vault"], 0) + 1
        if collective and ve_chirp and not ctx["low"]:
            try:
                coins = [v["coin"] for v in state["vaults"]]
                ok = turn_collective(collective, ve_chirp, coins, peg, ctx, state)
            except RpcError as e:
                print(f"{collective} rpc error {e}", flush=True)
                ok = False
            if not dry and ok is not None:
                state["fails"][collective] = 0 if ok else state["fails"].get(collective, 0) + 1
        if not dry:
            ctx["low"] = ctx["low"] or ctx["balance"] < max(LOW_WALLET_FLOOR, 7 * ctx["spent"])
    except Exception as e:
        crashed = f"{type(e).__name__}: {e}"
        print(f"run crashed: {crashed}", flush=True)
    today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    new_alerts, msgs = alerts(state, state["fails"], crashed, ctx["low"], today)
    for m in msgs:
        print(("DRY alert: " if dry else "alert: ") + m, flush=True)
        if not dry:
            telegram(m, env.get("TELEGRAM_CHAT_ID", ""))
    if not dry:
        state["alerts"] = new_alerts
    save_state(path, state)
    print(f"done: spent {ctx['spent']} wei", flush=True)
    return 1 if crashed else 0


if __name__ == "__main__":
    sys.exit(run(os.environ))
