from pathlib import Path


EA_SOURCE = (
    Path(__file__).parents[1] / "mt5" / "XAUUSD_5x5_CampaignBot.mq5"
).read_text(encoding="utf-8")


def test_ea_is_locked_to_xauusd_and_hedging_accounts():
    assert 'StringSubstr(_Symbol, 0, 6) != "XAUUSD"' in EA_SOURCE
    assert "ACCOUNT_MARGIN_MODE_RETAIL_HEDGING" in EA_SOURCE


def test_ea_places_five_orders_on_each_side_with_individual_tps():
    assert "for(int level = 1; level <= 5; level++)" in EA_SOURCE
    assert "Trade.BuyStop" in EA_SOURCE
    assert "Trade.SellStop" in EA_SOURCE
    assert "buy_tp" in EA_SOURCE
    assert "sell_tp" in EA_SOURCE


def test_active_campaign_continuously_replenishes_both_sides():
    assert 'while(CountSideExposure("B") < 5)' in EA_SOURCE
    assert 'while(CountSideExposure("S") < 5)' in EA_SOURCE
    assert 'CountSideExposure("B") == 5' in EA_SOURCE
    assert 'CountSideExposure("S") == 5' in EA_SOURCE
    assert 'SetEvent("LADDER_REPLENISHED"' in EA_SOURCE
    assert "if(!PlaceCampaignOrders())" in EA_SOURCE


def test_reused_slots_protect_positions_by_opening_order():
    assert "POSITION_TIME_MSC" in EA_SOURCE
    assert "ticket == newest_ticket" in EA_SOURCE


def test_ea_contains_all_money_and_breakeven_stops():
    assert 'BeginStop("PROFIT_TARGET_REACHED"' in EA_SOURCE
    assert 'BeginStop("MAX_LOSS_REACHED"' in EA_SOURCE
    assert 'BeginCampaignClose("CAMPAIGN_COMPLETE")' in EA_SOURCE
    assert 'BeginCampaignClose("CAMPAIGN_BREAKEVEN")' in EA_SOURCE
    assert "ProtectEarlierPositions(\"B\")" in EA_SOURCE
    assert "ProtectEarlierPositions(\"S\")" in EA_SOURCE


def test_campaign_target_defaults_to_five_dollars():
    assert "InpCampaignTargetMoney       = 5.0" in EA_SOURCE


def test_live_ladder_defaults_are_close_to_price():
    assert "InpFirstOrderDistancePrice    = 0.10" in EA_SOURCE
    assert "InpOrderSpacingPrice          = 0.10" in EA_SOURCE
    assert "InpIndividualTakeProfitPrice  = 2.00" in EA_SOURCE


def test_tp_is_realigned_to_the_actual_filled_entry():
    assert "AlignPositionTakeProfitsToFilledEntries()" in EA_SOURCE
    assert "open_price + InpIndividualTakeProfitPrice" in EA_SOURCE
    assert "open_price - InpIndividualTakeProfitPrice" in EA_SOURCE
    assert "Trade.PositionModify(ticket, current_sl, desired_tp)" in EA_SOURCE


def test_campaign_protection_accounts_for_exit_costs_and_slippage():
    assert "InpCampaignProtectionReserveMoney = 0.50" in EA_SOURCE
    assert "double EstimatedClosingCosts()" in EA_SOURCE
    assert "FloatingProfit() - EstimatedClosingCosts()" in EA_SOURCE
    assert "campaign_profit - InpCampaignProtectionReserveMoney" in EA_SOURCE
