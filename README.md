# XAU/USD 5×5 Campaign Bot

This is a separate gold version of the 5×5 campaign bot. It contains:

- an MT5 Expert Advisor for XAU/USD;
- a Railway-hosted live dashboard and control API;
- persistent dashboard settings;
- automated tests for the Railway service.

The XAU/USD bot has its own symbol lock, magic number, persistent-state prefix,
database path and browser-storage keys. It can run alongside the EUR/USD bot
without sharing trades or control state.

## Locked bot behaviour

1. A campaign places **5 Buy Stops and 5 Sell Stops** around the current XAU/USD price.
2. Every pending order has its own take-profit.
3. The whole campaign has a fixed **$5 combined profit target**. Combined profit means realised campaign profit plus current floating profit/loss.
4. At $5, the EA closes every open campaign trade, deletes every untriggered order and begins a fresh 5×5 campaign.
5. The Railway dashboard accepts any positive **overall profit target** and **maximum loss**. These apply to the complete run across all campaigns.
6. When the next order on one side triggers, every earlier open order on that same side moves to breakeven:
   - Buy 2 protects Buy 1;
   - Buy 3 protects Buy 1 and Buy 2;
   - the rule continues through Buy 5 and is identical for sells.
7. When combined campaign P/L first becomes positive, a $0 campaign floor is armed. If it returns to $0, every open campaign trade closes and all remaining pending orders are deleted. A fresh campaign then begins.
8. When the overall profit target or maximum loss is reached, everything closes, all pending orders are deleted and the bot stops.
9. The dashboard has one trading control: **TURN BOT OFF**. It performs the same full close, delete and stop operation.
10. After OFF, remove and reattach the EA in MT5 to begin a new run. The same attached session cannot turn itself back on.

Market execution can slip around an exact money threshold. The EA acts on the first tick at or beyond the threshold.

## Gold ladder defaults

Gold uses direct price distances rather than forex pips:

- first pending order distance: **$0.10** from current price;
- spacing between pending orders: **$0.10**;
- individual TP distance: **$2.00** from entry;
- lot size: **0.01**;
- breakeven price offset: **$0.00**.
- campaign protection reserve: **$0.50** after estimated closing costs.

For a standard XAU/USD contract where 0.01 lot represents one ounce, a $2.00
price move is approximately $2.00 gross P/L per position. Five positions have
approximately $10.00 of combined TP potential, but the EA closes the complete
campaign as soon as its combined P/L reaches the fixed $5 target. The exact result can
vary with the broker's contract specification, commission, swap and slippage.
The EA automatically respects any larger minimum stop distance imposed by the broker.

After a pending order fills, the EA resets its TP to exactly $2.00 from the
actual filled entry, so pending-order slippage cannot shorten the intended TP.
Campaign and overall P/L include an estimate of the commission needed to close
the positions. Breakeven protection arms only after those estimated closing
costs and the additional $0.50 safety reserve are covered.

The EA requires an **MT5 hedging account** because individual ladder positions must remain separate.

## Deploy a separate Railway service

1. Put this XAU/USD project in its own GitHub repository.
2. In Railway, create a new service from that repository. Do not point it at the EUR/USD repository.
3. A Railway volume mounted at `/data` is optional. It preserves event history, while the dashboard restores the last saved money limits after a redeploy.
4. Add new, gold-specific Railway variables:

   ```text
   BOT_API_KEY=make-this-a-new-long-private-key
   DASHBOARD_PASSWORD=your-private-dashboard-password
   SECRET_KEY=make-this-another-new-long-private-key
   STATE_DB_PATH=/data/xauusd-5x5.db
   ```

5. Generate a new Railway public domain for the gold service.

## Compile and attach the MT5 EA

1. Open MetaTrader 5.
2. Press **F4** to open MetaEditor.
3. Open the `MQL5/Experts` folder.
4. Copy `mt5/XAUUSD_5x5_CampaignBot.mq5` into that folder.
5. Open the file and press **F7** to compile it.
6. In MT5 go to **Tools → Options → Expert Advisors**.
7. Tick **Allow WebRequest for listed URL** and add the new gold Railway address.
8. Open an XAU/USD M5 chart and attach `XAUUSD_5x5_CampaignBot`.
9. In the EA inputs, paste the gold Railway URL and the gold `BOT_API_KEY`.
10. Enable Algo Trading.

The dashboard starts with editable defaults of $100 overall profit and $50 maximum loss.

## Backtest in MT5

1. Choose `XAUUSD_5x5_CampaignBot` and XAU/USD.
2. Select M5 and **Every tick based on real ticks**.
3. Set `InpUseRailway` to `false`.
4. Set `InpTesterOverallProfitTarget` and `InpTesterMaximumLoss`.
5. Keep `InpCampaignTargetMoney` at `5.0`.
6. Test price spacing and individual TP values through the MT5 Inputs tab.

## Run the Railway tests locally

```bash
python -m venv .venv
. .venv/bin/activate
pip install -r requirements-dev.txt
pytest -q
```
