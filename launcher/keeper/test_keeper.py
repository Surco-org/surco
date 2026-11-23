import io
import json
import os
import tempfile
import unittest
import urllib.error
from unittest import mock

import keeper
from keeper import MIN_CONVERT_WETH as M, LAUNCHED_TOPIC, alerts, classify, parse_launched, plan


class Pure(unittest.TestCase):
    def test_plan_seed_then_convert(self):
        self.assertEqual(plan(1, M, 0, 5, False), ["seed", "convert"])

    def test_plan_skips_convert_under_minimum(self):  # under 0.0005 ETH a convert is uneconomical
        self.assertEqual(M, 5 * 10**14)
        self.assertEqual(plan(1, M - 1, 0, 0, False), [])
        self.assertEqual(plan(1, M - 1, 0, 5, False), ["seed"])

    def test_plan_nothing(self):
        self.assertEqual(plan(1, 0, 0, 0, False), [])

    def test_plan_at_peg(self):
        self.assertEqual(plan(1, 0, 0, 0, True), ["buyback"])
        self.assertEqual(plan(0, M, 0, 0, True), ["convert", "claim"])
        self.assertEqual(plan(0, 1, 0, 0, True), ["claim"])

    def test_classify(self):
        self.assertEqual(classify("0x175c1aea"), "skip")
        self.assertEqual(classify("0x7dd37f70" + "00" * 4), "retry")
        self.assertEqual(classify(None), "fail")
        self.assertEqual(classify("0xdeadbeef"), "fail")

    def test_parse_launched(self):
        log = {"topics": [LAUNCHED_TOPIC, "0x" + "00" * 12 + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                          "0x" + "bb" * 32, "0x" + "00" * 32],
               "data": "0x" + "00" * 12 + "cccccccccccccccccccccccccccccccccccccccc" + f"{1:064x}" + f"{100:064x}" * 4}
        self.assertEqual(parse_launched(log), ("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                                               "0xcccccccccccccccccccccccccccccccccccccccc", 1))

    def test_alerts_once_per_day_and_recovery(self):
        s, m = alerts({}, {"0xv": 3}, None, False, "2026-11-22")
        self.assertEqual(len(m), 1)
        s, m = alerts({"alerts": s}, {"0xv": 4}, None, False, "2026-11-22")
        self.assertEqual(m, [])
        s, m = alerts({"alerts": s}, {"0xv": 0}, None, False, "2026-11-23")
        self.assertTrue(m[0].startswith("✅"))

    def test_alerts_crash_and_wallet(self):
        s, m = alerts({}, {}, "RpcError(boom)", True, "2026-11-22")
        self.assertEqual(len(m), 2)
        self.assertEqual(set(s), {"crash", "wallet"})


SAMPLE_LOG = {"topics": [LAUNCHED_TOPIC, "0x" + "00" * 12 + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                         "0x" + "bb" * 32, "0x" + "00" * 32],
              "data": "0x" + "00" * 12 + "cccccccccccccccccccccccccccccccccccccccc" + f"{1:064x}" + f"{100:064x}" * 4}


class FakeNet:
    """Stands in for urlopen: pops one canned reply per request; an Exception instance is raised instead."""

    def __init__(self, replies):
        self.replies, self.sent = list(replies), []

    def __call__(self, req, timeout=None):
        self.sent.append(json.loads(req.data))
        r = self.replies.pop(0)
        if isinstance(r, Exception):
            raise r
        return io.BytesIO(json.dumps({"jsonrpc": "2.0", "id": 1, **r}).encode())


class Chain(unittest.TestCase):
    def setUp(self):
        self.sleep = mock.patch("keeper.time.sleep").start()
        self.addCleanup(mock.patch.stopall)

    def net(self, replies):
        fake = FakeNet(replies)
        mock.patch("keeper._urlopen", fake).start()
        return fake

    def test_rpc_backs_off_on_429_then_succeeds(self):
        err = urllib.error.HTTPError("u", 429, "Too Many", {}, None)
        self.net([err, {"result": "0x1"}])
        self.assertEqual(keeper.rpc("eth_blockNumber", []), "0x1")
        self.sleep.assert_called_once_with(2)

    def test_rpc_gives_up_after_three_backoffs(self):
        self.net([{"error": {"code": -32011, "message": "request limit reached"}}] * 4)
        with self.assertRaises(keeper.RpcError):
            keeper.rpc("eth_blockNumber", [])
        self.assertEqual([c.args[0] for c in self.sleep.call_args_list], [2, 4, 8])

    def test_estimate_revert_carries_data(self):
        self.net([{"error": {"code": 3, "message": "execution reverted", "data": "0x175c1aea"}}])
        with self.assertRaises(keeper.RpcError) as cm:
            keeper.estimate("0x" + "11" * 20, "0x" + "22" * 20, "0x91bbdcc7")
        self.assertEqual(cm.exception.data, "0x175c1aea")
        self.assertEqual(classify(cm.exception.data), "skip")

    def test_load_state_corrupt_file(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "state.json")
            with open(p, "w") as f:
                f.write("{")
            self.assertEqual(keeper.load_state(p, 100),
                             {"last_block": 99, "vaults": [], "fails": {}, "alerts": {}})

    def test_save_then_load_round_trips(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "state.json")
            s = {"last_block": 5, "vaults": [{"vault": "0xv", "coin": "0xc", "mode": 1}], "fails": {}, "alerts": {}}
            keeper.save_state(p, s)
            self.assertEqual(keeper.load_state(p, 100), s)

    def test_discover_dedupes_and_advances(self):
        fake = self.net([{"result": [SAMPLE_LOG]}, {"result": [SAMPLE_LOG]}])
        with tempfile.TemporaryDirectory() as d:
            state = keeper.load_state(os.path.join(d, "s.json"), 100)
            keeper.discover(state, "0xfac", 40_099, os.path.join(d, "s.json"))
            self.assertEqual(len(state["vaults"]), 1)
            self.assertEqual(state["vaults"][0]["mode"], 1)
            self.assertEqual(state["last_block"], 40_099)
            self.assertEqual(fake.sent[0]["params"][0]["fromBlock"], hex(100))
            self.assertEqual(fake.sent[0]["params"][0]["toBlock"], hex(20_099))

    def test_discover_halves_chunk_on_error(self):
        fake = self.net([{"error": {"code": -32000, "message": "range too large"}}, {"result": []}, {"result": []}])
        with tempfile.TemporaryDirectory() as d:
            state = keeper.load_state(os.path.join(d, "s.json"), 100)
            keeper.discover(state, "0xfac", 20_099, os.path.join(d, "s.json"))
            self.assertEqual(fake.sent[1]["params"][0]["toBlock"], hex(10_099))
            self.assertEqual(state["last_block"], 20_099)


try:
    import eth_account
except ImportError:
    eth_account = None


@unittest.skipIf(eth_account is None, "needs eth_account")
class Sign(unittest.TestCase):
    def test_sign_lowercase_to_recovers_sender(self):
        a = eth_account.Account.create()
        raw = keeper.sign({"to": "0xcccccccccccccccccccccccccccccccccccccccc", "data": "0x91bbdcc7", "value": 0,
                           "gas": 1_850_000, "maxFeePerGas": 30_000_000, "maxPriorityFeePerGas": 1_000_000,
                           "nonce": 0, "chainId": 8453, "type": 2}, a.key)
        self.assertTrue(raw.startswith("0x02"))
        self.assertEqual(eth_account.Account.recover_transaction(raw), a.address)


class Turn(unittest.TestCase):
    V = {"vault": "0xv", "coin": "0xc", "mode": 1}

    def setUp(self):
        mock.patch("keeper.time.sleep").start()
        self.addCleanup(mock.patch.stopall)
        self.ctx = {"dry": False, "key": "k", "sender": "0xs", "nonce": 7, "max_fee": 10, "balance": 10**18,
                    "spent": 0, "low": False}

    def chain(self, pending_after, status=1):
        """weth=M so plan() says convert; pendingPintoWeth reads come from `pending_after` in order."""
        reads = iter([M, M, 0] + pending_after)  # weth, pending, pinto, then re-reads after each convert
        mock.patch("keeper.call", side_effect=lambda to, data: next(reads)).start()
        mock.patch("keeper.estimate", return_value=100).start()
        return mock.patch("keeper.send", return_value=("0xh", status, 90, 900)).start()

    def test_mined_revert_fails_vault_and_advances_nonce(self):
        self.chain([], status=0)
        self.assertFalse(keeper.turn(self.V, False, self.ctx))
        self.assertEqual(self.ctx["nonce"], 8)
        self.assertEqual(self.ctx["spent"], 900)

    def test_low_wallet_sends_nothing(self):
        send = self.chain([])
        self.ctx["balance"] = 100 * 13 // 10 * 10 - 1
        self.assertIsNone(keeper.turn(self.V, False, self.ctx))
        send.assert_not_called()
        self.assertTrue(self.ctx["low"])

    def test_converts_again_until_pending_clears(self):
        send = self.chain([M, 0])
        self.assertTrue(keeper.turn(self.V, False, self.ctx))
        self.assertEqual(send.call_count, 2)
        self.assertEqual(send.call_args.args[5], 130)  # gas = estimate x 1.3

    def test_no_second_convert_for_a_remainder_under_minimum(self):
        send = self.chain([M - 1])
        self.assertTrue(keeper.turn(self.V, False, self.ctx))
        self.assertEqual(send.call_count, 1)

    def test_converts_capped_at_five(self):
        send = self.chain([M] * 10)
        keeper.turn(self.V, False, self.ctx)
        self.assertEqual(send.call_count, 5)

    def test_dry_run_never_sends(self):
        send = self.chain([])
        self.ctx["dry"] = True
        self.assertTrue(keeper.turn(self.V, False, self.ctx))
        send.assert_not_called()


class Fixes(unittest.TestCase):
    """Final-review findings 11-21: each reproduces one way a single hiccup used to cost the rest of the run."""

    def setUp(self):
        mock.patch("keeper.time.sleep").start()
        self.addCleanup(mock.patch.stopall)

    def test_rpc_non_json_body_becomes_rpc_error(self):  # Important 2
        bodies = [b"<html>cloudflare</html>"] * 4

        def raw(req, timeout=None):
            return io.BytesIO(bodies.pop())
        mock.patch("keeper._urlopen", raw).start()
        with self.assertRaises(keeper.RpcError):
            keeper.rpc("eth_blockNumber", [])

    def test_send_keeps_polling_through_receipt_rpc_errors(self):  # Important 1a
        mock.patch("keeper.sign", return_value="0x02").start()
        replies = iter(["0xh", keeper.RpcError(-32011, "limit"), {"gasUsed": "0x5", "effectiveGasPrice": "0x2", "status": "0x1"}])

        def fake_rpc(method, params):
            r = next(replies)
            if isinstance(r, Exception):
                raise r
            return r
        mock.patch("keeper.rpc", side_effect=fake_rpc).start()
        self.assertEqual(keeper.send("k", "0xs", 1, "0xv", "0x", 10, 10), ("0xh", 1, 5, 10))

    def test_send_error_resyncs_nonce(self):  # Important 1b
        mock.patch("keeper.call", side_effect=[M, M, 0]).start()
        mock.patch("keeper.estimate", return_value=100).start()
        mock.patch("keeper.send", side_effect=keeper.RpcError(-32000, "already known")).start()
        mock.patch("keeper.rpc", return_value="0x9").start()
        ctx = {"dry": False, "key": "k", "sender": "0xs", "nonce": 7, "max_fee": 10, "balance": 10**18,
               "spent": 0, "low": False}
        with self.assertRaises(keeper.RpcError):
            keeper.turn({"vault": "0xv", "coin": "0xc", "mode": 1}, False, ctx)
        self.assertEqual(ctx["nonce"], 9)

    def test_balance_gate_reserves_l1_fee(self):  # promoted minor 6
        mock.patch("keeper.call", side_effect=[M, M, 0]).start()
        mock.patch("keeper.estimate", return_value=100).start()
        send = mock.patch("keeper.send").start()
        ctx = {"dry": False, "key": "k", "sender": "0xs", "nonce": 7, "max_fee": 10, "balance": 130 * 10 + 1,
               "spent": 0, "low": False}
        keeper.turn({"vault": "0xv", "coin": "0xc", "mode": 1}, False, ctx)
        send.assert_not_called()
        self.assertTrue(ctx["low"])


class Run(unittest.TestCase):
    """run() end to end with the chain stubbed by method name."""

    def setUp(self):
        mock.patch("keeper.time.sleep").start()
        self.addCleanup(mock.patch.stopall)
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = os.path.join(self.dir.name, "s.json")
        keeper.save_state(self.path, {"last_block": 10, "fails": {"0xa": 2, "0xb": 5}, "alerts": {},
                                      "vaults": [{"vault": "0xa", "coin": "0xc", "mode": 1},
                                                 {"vault": "0xb", "coin": "0xd", "mode": 1}]})
        answers = {"eth_blockNumber": "0xa", "eth_getBlockByNumber": {"baseFeePerGas": "0x5"},
                   "eth_getBalance": hex(10**18), "eth_getTransactionCount": "0x3"}
        mock.patch("keeper.rpc", side_effect=lambda m, p: answers[m]).start()
        mock.patch("keeper.call", return_value=0).start()
        mock.patch("keeper.telegram").start()
        self.env = {"FACTORY": "0xfac", "FACTORY_BLOCK": "1", "STATE": self.path, "DRY_RUN": "1", "SENDER": "0xs"}

    def state(self):
        return keeper.load_state(self.path, 1)

    def test_vault_error_counts_and_run_continues(self):  # Important 4 / Focus 1
        mock.patch("keeper.turn", side_effect=[keeper.RpcError(429, "HTTP 429"), True]).start()
        self.env["DRY_RUN"] = "0"
        mock.patch.dict("sys.modules", {"eth_account": mock.MagicMock()}).start()
        self.assertEqual(keeper.run(self.env), 0)
        self.assertEqual(self.state()["fails"], {"0xa": 3, "0xb": 0})

    def test_dry_run_leaves_fails_and_alerts(self):  # Important 4
        mock.patch("keeper.turn", return_value=False).start()
        keeper.run(self.env)
        self.assertEqual(self.state()["fails"], {"0xa": 2, "0xb": 5})
        self.assertEqual(self.state()["alerts"], {})

    def test_discover_failure_still_turns_known_vaults(self):  # Important 3
        mock.patch("keeper.discover", side_effect=keeper.RpcError(-32000, "getLogs down")).start()
        turn = mock.patch("keeper.turn", return_value=True).start()
        self.assertEqual(keeper.run(self.env), 1)  # still reported as a crash
        self.assertEqual(turn.call_count, 2)

    def test_low_wallet_stops_sending_and_keeps_streaks(self):  # promoted minor 5
        def low_first(v, peg, ctx):
            ctx["low"] = True
            return None
        turn = mock.patch("keeper.turn", side_effect=low_first).start()
        self.env["DRY_RUN"] = "0"
        mock.patch.dict("sys.modules", {"eth_account": mock.MagicMock()}).start()
        keeper.run(self.env)
        self.assertEqual(turn.call_count, 1)
        self.assertEqual(self.state()["fails"], {"0xa": 2, "0xb": 5})


class Collective(unittest.TestCase):
    COL = "0x" + "cc" * 20
    VE = "0x" + "ee" * 20
    COIN = "0x" + "aa" * 20

    def setUp(self):
        mock.patch("keeper.time.sleep").start()
        self.addCleanup(mock.patch.stopall)
        self.ctx = {"dry": False, "key": "k", "sender": "0xs", "nonce": 1, "max_fee": 10, "balance": 10**18,
                    "spent": 0, "low": False}

    def test_plan_collective_and_encode_distribute(self):
        self.assertEqual(keeper.plan_collective(M, 10, True), ["seed", "convert", "plant"])
        self.assertEqual(keeper.plan_collective(M - 1, 0, False), [])
        cd = keeper.encode_distribute(self.COIN, [20100, 20101], 50_000_000)
        self.assertTrue(cd.startswith("0xabc0eebd"))
        self.assertEqual(len(cd), 10 + 64 * 6)  # selector + coin + offset + maxPinto + len + 2 days

    def test_turn_collective_seeds_converts_plants_and_distributes(self):
        def fake_call(to, data):
            if to == keeper.WETH:
                return M if send.call_count < 2 else 0  # WETH clears after convert
            if to == keeper.PINTO:
                return 100
            if to == self.COL and data == keeper.SEL["plant"]:
                return 25_000_000  # 25 Pinto plantable
            if to == self.VE and data == keeper.SEL["currentDay"]:
                return 20105
            if to == self.COL and data.startswith(keeper.SEL["dayPinto"]):
                return 10_000_000 if data.endswith(keeper.uword(20104)) else 0
            if to == self.COL and data.startswith(keeper.SEL["dayTotalWeight"]):
                return 1_000
            if to == self.VE and data.startswith(keeper.SEL["coinWeightAt"]):
                return 500
            if to == self.COL and data.startswith(keeper.SEL["coinDayPaidPinto"]):
                return 0
            return 0

        mock.patch("keeper.call", side_effect=fake_call).start()
        mock.patch("keeper.estimate", return_value=200).start()
        send = mock.patch("keeper.send", return_value=("0xh", 1, 180, 1800)).start()
        self.assertTrue(keeper.turn_collective(self.COL, self.VE, [self.COIN], True, self.ctx))
        # Expect: seed, convert, plant, distribute(COIN, [20104], 5_000_000)
        self.assertEqual(send.call_count, 4)
        sent_data = [c.args[4] for c in send.call_args_list]
        self.assertEqual(sent_data[0], keeper.SEL["seed"])
        self.assertEqual(sent_data[1], keeper.SEL["convert"])
        self.assertEqual(sent_data[2], keeper.SEL["plant"])
        self.assertEqual(sent_data[3], keeper.encode_distribute(self.COIN, [20104], 5_000_000))

    def test_turn_collective_skips_zero_plant_and_dust_distribute(self):
        def fake_call(to, data):
            if to == self.VE and data == keeper.SEL["currentDay"]:
                return 20105
            if to == self.COL and data.startswith(keeper.SEL["dayPinto"]):
                return 100_000 if data.endswith(keeper.uword(20104)) else 0  # 0.10 Pinto < 0.50 floor
            if to == self.COL and data.startswith(keeper.SEL["dayTotalWeight"]):
                return 100
            if to == self.VE and data.startswith(keeper.SEL["coinWeightAt"]):
                return 100
            return 0

        mock.patch("keeper.call", side_effect=fake_call).start()
        send = mock.patch("keeper.send").start()
        self.assertTrue(keeper.turn_collective(self.COL, self.VE, [self.COIN], True, self.ctx))
        send.assert_not_called()

    def test_turn_collective_halves_max_pinto_on_slippage(self):
        paid = {"amt": 0}

        def fake_call(to, data):
            if to == self.VE and data == keeper.SEL["currentDay"]:
                return 20105
            if to == self.COL and data.startswith(keeper.SEL["dayPinto"]):
                return 10_000_000 if data.endswith(keeper.uword(20104)) else 0
            if to == self.COL and data.startswith(keeper.SEL["dayTotalWeight"]):
                return 100
            if to == self.VE and data.startswith(keeper.SEL["coinWeightAt"]):
                return 100
            if to == self.COL and data.startswith(keeper.SEL["coinDayPaidPinto"]):
                return paid["amt"]
            return 0

        def fake_send(*args):
            paid["amt"] += 5_000_000
            return ("0xh", 1, 200, 2000)

        mock.patch("keeper.call", side_effect=fake_call).start()
        mock.patch("keeper.rpc", return_value="0x" + "00" * 64).start()
        est = mock.patch("keeper.estimate", side_effect=[keeper.RpcError(3, "rev", "0x7dd37f70"), 250, 250]).start()
        send = mock.patch("keeper.send", side_effect=fake_send).start()
        self.assertTrue(keeper.turn_collective(self.COL, self.VE, [self.COIN], True, self.ctx))
        # First estimate reverted Slippage -> halved to 5M (succeeded), then loop finished the remaining 5M!
        self.assertEqual(est.call_count, 3)
        self.assertEqual(send.call_count, 2)
        self.assertEqual(send.call_args_list[0].args[4], keeper.encode_distribute(self.COIN, [20104], 5_000_000))
        self.assertEqual(send.call_args_list[1].args[4], keeper.encode_distribute(self.COIN, [20104], 5_000_000))

    def test_turn_collective_distributes_below_peg_and_isolates_convert_slippage(self):
        def fake_call(to, data):
            if to == keeper.WETH:
                return M
            if to == self.VE and data == keeper.SEL["currentDay"]:
                return 20105
            if to == self.COL and data.startswith(keeper.SEL["dayPinto"]):
                return 2_000_000 if data.endswith(keeper.uword(20104)) else 0
            if to == self.COL and data.startswith(keeper.SEL["dayTotalWeight"]):
                return 100
            if to == self.VE and data.startswith(keeper.SEL["coinWeightAt"]):
                return 100
            return 0

        mock.patch("keeper.call", side_effect=fake_call).start()
        mock.patch("keeper.rpc", return_value="0x" + "00" * 64).start()
        # convert() hits Slippage, yet distribute() STILL runs below peg!
        mock.patch("keeper.estimate", side_effect=[keeper.RpcError(3, "rev", "0x7dd37f70"), 200]).start()
        send = mock.patch("keeper.send", return_value=("0xh", 1, 180, 1800)).start()
        state = {"collective_day": 20104}
        self.assertFalse(keeper.turn_collective(self.COL, self.VE, [self.COIN], False, self.ctx, state))
        self.assertEqual(send.call_count, 1)
        self.assertEqual(send.call_args.args[4], keeper.encode_distribute(self.COIN, [20104], 2_000_000))
        self.assertEqual(state["collective_day"], 20105)

    def test_turn_collective_finishes_partial_day_below_floor_and_skips_sub_cent_dust(self):
        # Day 20103 has 5_000 raw Pinto (< MIN_DAY_ENTITLED = 10_000 -> ignored);
        # Day 20104 has 1_000_000 entitled with 900_000 already paid (100_000 remaining < 500_000 floor,
        # but partial so keeper MUST finish it!).
        def fake_call(to, data):
            if to == self.VE and data == keeper.SEL["currentDay"]:
                return 20105
            if to == self.COL and data.startswith(keeper.SEL["dayPinto"]):
                if data.endswith(keeper.uword(20103)):
                    return 5_000
                if data.endswith(keeper.uword(20104)):
                    return 1_000_000
            if to == self.COL and data.startswith(keeper.SEL["dayTotalWeight"]):
                return 100
            if to == self.VE and data.startswith(keeper.SEL["coinWeightAt"]):
                return 100
            if to == self.COL and data.startswith(keeper.SEL["coinDayPaidPinto"]):
                return 900_000 if data.endswith(keeper.uword(20104)) else 0
            return 0

        mock.patch("keeper.call", side_effect=fake_call).start()
        mock.patch("keeper.rpc", return_value="0x" + "00" * 64).start()
        mock.patch("keeper.estimate", return_value=200).start()
        send = mock.patch("keeper.send", return_value=("0xh", 1, 180, 1800)).start()
        self.assertTrue(keeper.turn_collective(self.COL, self.VE, [self.COIN], False, self.ctx))
        self.assertEqual(send.call_count, 1)
        self.assertEqual(send.call_args.args[4], keeper.encode_distribute(self.COIN, [20104], 100_000))

    def test_turn_collective_large_day_exceeding_max_distributes_preserves_earliest_unsettled(self):
        # Day 20104 has 12,000 Pinto (> 5 * 2,000 MAX_BUYBACK_PINTO). After 5 batches, 2,000 Pinto remains,
        # so state["collective_day"] must stay at 20104 rather than advancing to 20105.
        paid = {"amt": 0}

        def fake_call(to, data):
            if to == self.VE and data == keeper.SEL["currentDay"]:
                return 20105
            if to == self.COL and data.startswith(keeper.SEL["dayPinto"]):
                return 12_000 * 10**6 if data.endswith(keeper.uword(20104)) else 0
            if to == self.COL and data.startswith(keeper.SEL["dayTotalWeight"]):
                return 100
            if to == self.VE and data.startswith(keeper.SEL["coinWeightAt"]):
                return 100
            if to == self.COL and data.startswith(keeper.SEL["coinDayPaidPinto"]):
                return paid["amt"]
            return 0

        def fake_send(*args):
            paid["amt"] += keeper.MAX_BUYBACK_PINTO
            return ("0xh", 1, 200, 2000)

        mock.patch("keeper.call", side_effect=fake_call).start()
        mock.patch("keeper.rpc", return_value="0x" + "00" * 64).start()
        mock.patch("keeper.estimate", return_value=200).start()
        send = mock.patch("keeper.send", side_effect=fake_send).start()
        state = {}
        self.assertTrue(keeper.turn_collective(self.COL, self.VE, [self.COIN], False, self.ctx, state))
        self.assertEqual(send.call_count, keeper.MAX_DISTRIBUTES)
        self.assertEqual(state["collective_day"], 20104)


if __name__ == "__main__":
    unittest.main()
