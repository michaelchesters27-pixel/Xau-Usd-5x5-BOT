#property copyright "EVE XAUUSD 5x5 Campaign Bot"
#property version   "1.02"
#property strict
#property description "XAUUSD 5 buy-stop / 5 sell-stop campaign EA with Railway control"

#include <Trade/Trade.mqh>

CTrade Trade;

input group "XAU/USD ladder"
input double InpLotSize                    = 0.01;
input double InpFirstOrderDistancePrice    = 0.10;
input double InpOrderSpacingPrice          = 0.10;
input double InpIndividualTakeProfitPrice  = 2.00;
input double InpBreakevenOffsetPrice       = 0.0;
input long   InpMagicNumber                = 550099;
input int    InpSlippagePoints             = 20;

input group "Railway control"
input bool   InpUseRailway               = true;
input string InpRailwayUrl               = "https://YOUR-SERVICE.up.railway.app";
input string InpBotApiKey                = "CHANGE-ME";
input int    InpRailwayPollSeconds       = 2;
input int    InpRemoteFailSafeSeconds    = 30;

input group "Strategy Tester only"
input double InpTesterOverallProfitTarget = 100.0;
input double InpTesterMaximumLoss         = 50.0;
input double InpCampaignTargetMoney       = 5.0;

string   g_session_id = "";
string   g_status = "WAITING_FOR_LIMITS";
string   g_event = "";
string   g_message = "";
string   g_stop_reason = "";
string   g_campaign_end_reason = "";
string   g_gv_prefix = "";

bool     g_testing = false;
bool     g_registered = false;
bool     g_remote_enabled = false;
bool     g_local_stopped = false;
bool     g_stopping = false;
bool     g_campaign_active = false;
bool     g_campaign_closing = false;
bool     g_campaign_profit_armed = false;

double   g_profit_target = 0.0;
double   g_max_loss = 0.0;
double   g_campaign_target = 5.0;
double   g_run_realized = 0.0;
double   g_campaign_realized = 0.0;

datetime g_run_start = 0;
datetime g_campaign_start = 0;
datetime g_next_campaign_attempt = 0;
datetime g_last_server_contact = 0;
int      g_campaign_number = 1;


double NormalizedPrice(const double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}


string BaseUrl()
{
   string url = InpRailwayUrl;
   while(StringLen(url) > 0 && StringSubstr(url, StringLen(url) - 1, 1) == "/")
      url = StringSubstr(url, 0, StringLen(url) - 1);
   return url;
}


string JsonEscape(string value)
{
   StringReplace(value, "\\", "\\\\");
   StringReplace(value, "\"", "\\\"");
   StringReplace(value, "\r", " ");
   StringReplace(value, "\n", " ");
   return value;
}


int JsonValueStart(const string json, const string key)
{
   string token = "\"" + key + "\"";
   int position = StringFind(json, token);
   if(position < 0)
      return -1;
   position = StringFind(json, ":", position + StringLen(token));
   if(position < 0)
      return -1;
   position++;
   while(position < StringLen(json))
   {
      string character = StringSubstr(json, position, 1);
      if(character != " " && character != "\t" && character != "\r" && character != "\n")
         break;
      position++;
   }
   return position;
}


double JsonNumber(const string json, const string key, const double fallback)
{
   int start = JsonValueStart(json, key);
   if(start < 0)
      return fallback;
   int finish = start;
   while(finish < StringLen(json))
   {
      string character = StringSubstr(json, finish, 1);
      if(StringFind("-+0123456789.eE", character) < 0)
         break;
      finish++;
   }
   if(finish <= start)
      return fallback;
   return StringToDouble(StringSubstr(json, start, finish - start));
}


bool JsonBool(const string json, const string key, const bool fallback)
{
   int start = JsonValueStart(json, key);
   if(start < 0)
      return fallback;
   if(StringSubstr(json, start, 4) == "true")
      return true;
   if(StringSubstr(json, start, 5) == "false")
      return false;
   return fallback;
}


int HttpRequest(const string method, const string endpoint, const string body, string &response)
{
   char request_data[];
   char result_data[];
   string result_headers;
   string headers = "Content-Type: application/json\r\nX-Bot-Key: " + InpBotApiKey + "\r\n";

   if(StringLen(body) > 0)
   {
      int copied = StringToCharArray(body, request_data, 0, WHOLE_ARRAY, CP_UTF8);
      if(copied > 0)
         ArrayResize(request_data, copied - 1);
   }
   else
      ArrayResize(request_data, 0);

   ResetLastError();
   int status_code = WebRequest(method, BaseUrl() + endpoint, headers, 5000,
                                request_data, result_data, result_headers);
   if(status_code == -1)
   {
      Print("Railway WebRequest failed. MT5 error: ", GetLastError());
      response = "";
      return -1;
   }

   response = CharArrayToString(result_data, 0, -1, CP_UTF8);
   if(status_code >= 200 && status_code < 300)
      g_last_server_contact = TimeLocal();
   return status_code;
}


void SetEvent(const string event_name, const string message)
{
   g_event = event_name;
   g_message = message;
   Print(message);
}


string GlobalKey(const string suffix)
{
   return g_gv_prefix + suffix;
}


void SavePersistentState()
{
   GlobalVariableSet(GlobalKey("RUN"), (double)g_run_start);
   GlobalVariableSet(GlobalKey("CAMPAIGN"), (double)g_campaign_start);
   GlobalVariableSet(GlobalKey("NUMBER"), (double)g_campaign_number);
   GlobalVariableSet(GlobalKey("ARMED"), g_campaign_profit_armed ? 1.0 : 0.0);
   GlobalVariableSet(GlobalKey("STOPPED"), g_local_stopped ? 1.0 : 0.0);
}


void DeletePersistentState()
{
   GlobalVariableDel(GlobalKey("RUN"));
   GlobalVariableDel(GlobalKey("CAMPAIGN"));
   GlobalVariableDel(GlobalKey("NUMBER"));
   GlobalVariableDel(GlobalKey("ARMED"));
   GlobalVariableDel(GlobalKey("STOPPED"));
}


void RestorePersistentState()
{
   if(GlobalVariableCheck(GlobalKey("RUN")))
      g_run_start = (datetime)GlobalVariableGet(GlobalKey("RUN"));
   if(GlobalVariableCheck(GlobalKey("CAMPAIGN")))
      g_campaign_start = (datetime)GlobalVariableGet(GlobalKey("CAMPAIGN"));
   if(GlobalVariableCheck(GlobalKey("NUMBER")))
      g_campaign_number = (int)GlobalVariableGet(GlobalKey("NUMBER"));
   if(GlobalVariableCheck(GlobalKey("ARMED")))
      g_campaign_profit_armed = GlobalVariableGet(GlobalKey("ARMED")) > 0.5;
   if(GlobalVariableCheck(GlobalKey("STOPPED")))
      g_local_stopped = GlobalVariableGet(GlobalKey("STOPPED")) > 0.5;
}


bool IsOwnedPositionSelected()
{
   return PositionGetString(POSITION_SYMBOL) == _Symbol &&
          PositionGetInteger(POSITION_MAGIC) == InpMagicNumber;
}


bool IsOwnedOrderSelected()
{
   if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
      return false;
   ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
   return type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP;
}


int CountOwnedPositions()
{
   int count = 0;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
   {
      if(PositionGetTicket(index) > 0 && IsOwnedPositionSelected())
         count++;
   }
   return count;
}


int CountOwnedOrders()
{
   int count = 0;
   for(int index = OrdersTotal() - 1; index >= 0; index--)
   {
      if(OrderGetTicket(index) > 0 && IsOwnedOrderSelected())
         count++;
   }
   return count;
}


bool HasOwnedExposure()
{
   return CountOwnedPositions() > 0 || CountOwnedOrders() > 0;
}


datetime EarliestOwnedExposureTime()
{
   datetime earliest = TimeCurrent();
   bool found = false;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
   {
      if(PositionGetTicket(index) <= 0 || !IsOwnedPositionSelected())
         continue;
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      if(!found || opened < earliest)
         earliest = opened;
      found = true;
   }
   for(int index = OrdersTotal() - 1; index >= 0; index--)
   {
      if(OrderGetTicket(index) <= 0 || !IsOwnedOrderSelected())
         continue;
      datetime placed = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(!found || placed < earliest)
         earliest = placed;
      found = true;
   }
   return found ? earliest : TimeCurrent();
}


double ClosedProfitSince(const datetime since)
{
   if(since <= 0 || !HistorySelect(since, TimeCurrent() + 60))
      return 0.0;
   double total = 0.0;
   int deals = HistoryDealsTotal();
   for(int index = 0; index < deals; index++)
   {
      ulong ticket = HistoryDealGetTicket(index);
      if(ticket == 0)
         continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol ||
         HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagicNumber)
         continue;
      total += HistoryDealGetDouble(ticket, DEAL_PROFIT);
      total += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      total += HistoryDealGetDouble(ticket, DEAL_SWAP);
      total += HistoryDealGetDouble(ticket, DEAL_FEE);
   }
   return total;
}


double FloatingProfit()
{
   double total = 0.0;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
   {
      if(PositionGetTicket(index) <= 0 || !IsOwnedPositionSelected())
         continue;
      total += PositionGetDouble(POSITION_PROFIT);
      total += PositionGetDouble(POSITION_SWAP);
   }
   return total;
}


double RunProfit()
{
   return g_run_realized + FloatingProfit();
}


double CampaignProfit()
{
   return g_campaign_realized + FloatingProfit();
}


int ParseLevel(const string comment, const string side)
{
   string marker = "|" + side;
   int position = StringFind(comment, marker);
   if(position < 0)
      return 0;
   return (int)StringToInteger(StringSubstr(comment, position + StringLen(marker), 1));
}


string OrderComment(const string side, const int level)
{
   return "G5C" + IntegerToString(g_campaign_number) + "|" + side + IntegerToString(level);
}


bool WasLevelTriggered(const string side, const int level)
{
   if(g_campaign_start <= 0 || !HistorySelect(g_campaign_start, TimeCurrent() + 60))
      return false;
   for(int index = HistoryDealsTotal() - 1; index >= 0; index--)
   {
      ulong ticket = HistoryDealGetTicket(index);
      if(ticket == 0 || HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol ||
         HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagicNumber)
         continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_IN && entry != DEAL_ENTRY_INOUT)
         continue;
      if(ParseLevel(HistoryDealGetString(ticket, DEAL_COMMENT), side) == level)
         return true;
   }
   return false;
}


int HighestTriggeredLevel(const string side)
{
   int highest = 0;
   for(int level = 1; level <= 5; level++)
      if(WasLevelTriggered(side, level))
         highest = level;
   return highest;
}


void ProtectEarlierPositions(const string side)
{
   int highest = HighestTriggeredLevel(side);
   if(highest < 2)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;
   double minimum_distance = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double offset = MathMax(0.0, InpBreakevenOffsetPrice);

   for(int index = PositionsTotal() - 1; index >= 0; index--)
   {
      ulong ticket = PositionGetTicket(index);
      if(ticket == 0 || !IsOwnedPositionSelected())
         continue;
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      string position_side = type == POSITION_TYPE_BUY ? "B" : "S";
      if(position_side != side)
         continue;
      int level = ParseLevel(PositionGetString(POSITION_COMMENT), side);
      if(level <= 0 || level >= highest)
         continue;

      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double current_sl = PositionGetDouble(POSITION_SL);
      double current_tp = PositionGetDouble(POSITION_TP);
      double new_sl = type == POSITION_TYPE_BUY ? open_price + offset : open_price - offset;
      new_sl = NormalizedPrice(new_sl);

      bool already_protected = type == POSITION_TYPE_BUY
                               ? current_sl >= new_sl - (_Point * 0.5)
                               : (current_sl > 0.0 && current_sl <= new_sl + (_Point * 0.5));
      if(already_protected)
         continue;

      bool price_allows = type == POSITION_TYPE_BUY
                          ? new_sl < tick.bid - minimum_distance
                          : new_sl > tick.ask + minimum_distance;
      if(!price_allows)
         continue;

      if(!Trade.PositionModify(ticket, new_sl, current_tp))
         Print("Could not move ", side, level, " to breakeven: ", Trade.ResultRetcodeDescription());
      else
         SetEvent("LEVEL_PROTECTED", (side == "B" ? "Buy " : "Sell ") +
                  IntegerToString(level) + " moved to breakeven");
   }
}


void ManageLadderBreakeven()
{
   ProtectEarlierPositions("B");
   ProtectEarlierPositions("S");
}


bool DeleteOwnedOrders()
{
   bool success = true;
   for(int index = OrdersTotal() - 1; index >= 0; index--)
   {
      ulong ticket = OrderGetTicket(index);
      if(ticket == 0 || !IsOwnedOrderSelected())
         continue;
      if(!Trade.OrderDelete(ticket))
      {
         success = false;
         Print("Could not delete pending order ", ticket, ": ", Trade.ResultRetcodeDescription());
      }
   }
   return success;
}


bool CloseOwnedPositions()
{
   bool success = true;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
   {
      ulong ticket = PositionGetTicket(index);
      if(ticket == 0 || !IsOwnedPositionSelected())
         continue;
      if(!Trade.PositionClose(ticket, (ulong)InpSlippagePoints))
      {
         success = false;
         Print("Could not close position ", ticket, ": ", Trade.ResultRetcodeDescription());
      }
   }
   return success;
}


bool FlattenOwnedExposure()
{
   DeleteOwnedOrders();
   CloseOwnedPositions();
   return !HasOwnedExposure();
}


bool PlaceCampaignOrders()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double broker_minimum = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point + _Point;
   double first_distance = MathMax(InpFirstOrderDistancePrice, broker_minimum);
   double spacing = MathMax(InpOrderSpacingPrice, _Point);
   double take_profit_distance = MathMax(InpIndividualTakeProfitPrice, broker_minimum);

   bool success = true;
   for(int level = 1; level <= 5; level++)
   {
      double buy_price = NormalizedPrice(tick.ask + first_distance + (level - 1) * spacing);
      double buy_tp = NormalizedPrice(buy_price + take_profit_distance);
      if(!Trade.BuyStop(InpLotSize, buy_price, _Symbol, 0.0, buy_tp,
                        ORDER_TIME_GTC, 0, OrderComment("B", level)))
      {
         Print("Buy Stop ", level, " failed: ", Trade.ResultRetcodeDescription());
         success = false;
      }

      double sell_price = NormalizedPrice(tick.bid - first_distance - (level - 1) * spacing);
      double sell_tp = NormalizedPrice(sell_price - take_profit_distance);
      if(!Trade.SellStop(InpLotSize, sell_price, _Symbol, 0.0, sell_tp,
                         ORDER_TIME_GTC, 0, OrderComment("S", level)))
      {
         Print("Sell Stop ", level, " failed: ", Trade.ResultRetcodeDescription());
         success = false;
      }
   }
   return success && CountOwnedOrders() == 10;
}


void StartCampaign()
{
   if(TimeCurrent() < g_next_campaign_attempt || HasOwnedExposure())
      return;

   g_campaign_start = TimeCurrent();
   g_campaign_realized = 0.0;
   g_campaign_profit_armed = false;
   g_campaign_active = true;
   SavePersistentState();

   if(!PlaceCampaignOrders())
   {
      FlattenOwnedExposure();
      g_campaign_active = false;
      g_campaign_start = 0;
      g_next_campaign_attempt = TimeCurrent() + 5;
      g_status = "PLACEMENT_RETRY";
      SetEvent("PLACEMENT_ERROR", "Could not place the complete 5x5 ladder; retrying in 5 seconds");
      return;
   }

   g_status = "RUNNING";
   SetEvent("CAMPAIGN_STARTED", "Campaign " + IntegerToString(g_campaign_number) +
            " started with 5 buy stops and 5 sell stops");
}


void BeginCampaignClose(const string reason)
{
   if(g_campaign_closing)
      return;
   g_campaign_closing = true;
   g_campaign_end_reason = reason;
   DeleteOwnedOrders();
   CloseOwnedPositions();
}


void ContinueCampaignClose()
{
   if(!g_campaign_closing)
      return;
   if(!FlattenOwnedExposure())
      return;

   string reason = g_campaign_end_reason;
   if(reason == "CAMPAIGN_COMPLETE")
      SetEvent("CAMPAIGN_COMPLETE", "Campaign " + IntegerToString(g_campaign_number) +
               " reached its $" + DoubleToString(g_campaign_target, 2) + " target");
   else
      SetEvent("CAMPAIGN_BREAKEVEN", "Campaign " + IntegerToString(g_campaign_number) +
               " closed by campaign breakeven protection");

   g_status = reason;
   g_campaign_number++;
   g_campaign_active = false;
   g_campaign_closing = false;
   g_campaign_profit_armed = false;
   g_campaign_start = 0;
   g_campaign_realized = 0.0;
   g_next_campaign_attempt = TimeCurrent() + 1;
   SavePersistentState();
}


void BeginStop(const string reason, const string message)
{
   if(g_stopping || g_local_stopped)
      return;
   g_stopping = true;
   g_stop_reason = reason;
   g_remote_enabled = false;
   g_status = reason;
   SetEvent(reason, message);
   DeleteOwnedOrders();
   CloseOwnedPositions();
}


void ContinueStop()
{
   if(!g_stopping)
      return;
   if(!FlattenOwnedExposure())
      return;
   g_stopping = false;
   g_local_stopped = true;
   g_status = g_stop_reason;
   g_campaign_active = false;
   g_campaign_closing = false;
   SavePersistentState();
}


void ApplyRemoteConfig(const string response)
{
   g_remote_enabled = JsonBool(response, "enabled", g_remote_enabled);
   g_profit_target = JsonNumber(response, "profit_target", g_profit_target);
   g_max_loss = JsonNumber(response, "max_loss", g_max_loss);
   g_campaign_target = JsonNumber(response, "campaign_target", g_campaign_target);
}


bool RegisterRemoteSession()
{
   string body = "{\"session_id\":\"" + JsonEscape(g_session_id) + "\"}";
   string response;
   int code = HttpRequest("POST", "/api/ea/start", body, response);
   if(code >= 200 && code < 300)
   {
      g_registered = true;
      ApplyRemoteConfig(response);
      SetEvent("MT5_CONNECTED", "MT5 connected to Railway");
      return true;
   }
   if(code == 409)
   {
      g_status = "WAITING_FOR_LIMITS";
      g_remote_enabled = false;
   }
   return false;
}


void FetchRemoteConfig()
{
   string response;
   int code = HttpRequest("GET", "/api/ea/config?session_id=" + g_session_id, "", response);
   if(code < 200 || code >= 300)
      return;
   ApplyRemoteConfig(response);
   if(!g_remote_enabled && !g_local_stopped && !g_stopping)
      BeginStop("MANUAL_OFF", "Railway OFF pressed: closing every trade and deleting every order");
}


string LevelJson(const string side, const int level)
{
   string state = "WAITING";
   double entry = 0.0;
   double stop_loss = 0.0;
   double take_profit = 0.0;
   double profit = 0.0;
   bool found = false;

   for(int index = PositionsTotal() - 1; index >= 0 && !found; index--)
   {
      if(PositionGetTicket(index) <= 0 || !IsOwnedPositionSelected())
         continue;
      if(ParseLevel(PositionGetString(POSITION_COMMENT), side) != level)
         continue;
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((side == "B" && type != POSITION_TYPE_BUY) ||
         (side == "S" && type != POSITION_TYPE_SELL))
         continue;
      entry = PositionGetDouble(POSITION_PRICE_OPEN);
      stop_loss = PositionGetDouble(POSITION_SL);
      take_profit = PositionGetDouble(POSITION_TP);
      profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      bool protected_at_be = stop_loss > 0.0 &&
         (side == "B" ? stop_loss >= entry - _Point : stop_loss <= entry + _Point);
      state = protected_at_be ? "BREAKEVEN" : "OPEN";
      found = true;
   }

   for(int index = OrdersTotal() - 1; index >= 0 && !found; index--)
   {
      if(OrderGetTicket(index) <= 0 || !IsOwnedOrderSelected())
         continue;
      if(ParseLevel(OrderGetString(ORDER_COMMENT), side) != level)
         continue;
      entry = OrderGetDouble(ORDER_PRICE_OPEN);
      stop_loss = OrderGetDouble(ORDER_SL);
      take_profit = OrderGetDouble(ORDER_TP);
      state = "PENDING";
      found = true;
   }

   if(!found && WasLevelTriggered(side, level))
      state = "CLOSED";

   return "{\"side\":\"" + (side == "B" ? "BUY" : "SELL") +
          "\",\"level\":" + IntegerToString(level) +
          ",\"state\":\"" + state +
          "\",\"entry\":" + DoubleToString(entry, _Digits) +
          ",\"sl\":" + DoubleToString(stop_loss, _Digits) +
          ",\"tp\":" + DoubleToString(take_profit, _Digits) +
          ",\"pl\":" + DoubleToString(profit, 2) + "}";
}


string LevelsJson()
{
   string json = "[";
   bool first = true;
   for(int side_index = 0; side_index < 2; side_index++)
   {
      string side = side_index == 0 ? "B" : "S";
      for(int level = 1; level <= 5; level++)
      {
         if(!first)
            json += ",";
         json += LevelJson(side, level);
         first = false;
      }
   }
   return json + "]";
}


void SendTelemetry()
{
   if(!InpUseRailway || g_testing || !g_registered)
      return;

   string body = "{";
   body += "\"session_id\":\"" + JsonEscape(g_session_id) + "\",";
   body += "\"status\":\"" + JsonEscape(g_status) + "\",";
   body += "\"message\":\"" + JsonEscape(g_message) + "\",";
   body += "\"event\":\"" + JsonEscape(g_event) + "\",";
   body += "\"symbol\":\"" + JsonEscape(_Symbol) + "\",";
   body += "\"timeframe\":\"M5\",";
   body += "\"campaign_number\":" + IntegerToString(g_campaign_number) + ",";
   body += "\"run_pl\":" + DoubleToString(RunProfit(), 2) + ",";
   body += "\"campaign_pl\":" + DoubleToString(CampaignProfit(), 2) + ",";
   body += "\"balance\":" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + ",";
   body += "\"equity\":" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + ",";
   body += "\"open_positions\":" + IntegerToString(CountOwnedPositions()) + ",";
   body += "\"pending_orders\":" + IntegerToString(CountOwnedOrders()) + ",";
   body += "\"campaign_breakeven_armed\":" + (g_campaign_profit_armed ? "true" : "false") + ",";
   body += "\"levels\":" + LevelsJson();
   body += "}";

   string response;
   int code = HttpRequest("POST", "/api/ea/telemetry", body, response);
   if(code >= 200 && code < 300)
   {
      g_event = "";
      if(g_status == "RUNNING")
         g_message = "Campaign " + IntegerToString(g_campaign_number) + " is live";
   }
}


int OnInit()
{
   g_testing = (bool)MQLInfoInteger(MQL_TESTER);
   if(StringLen(_Symbol) < 6 || StringSubstr(_Symbol, 0, 6) != "XAUUSD")
   {
      Alert("This EA is for XAUUSD only.");
      return INIT_FAILED;
   }
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Alert("The XAUUSD 5x5 bot requires an MT5 hedging account.");
      return INIT_FAILED;
   }
   if(InpLotSize <= 0 || InpFirstOrderDistancePrice <= 0 || InpOrderSpacingPrice <= 0 ||
      InpIndividualTakeProfitPrice <= 0 || InpCampaignTargetMoney <= 0)
   {
      Alert("Lot size, distances and targets must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
   }

   Trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   Trade.SetDeviationInPoints(InpSlippagePoints);
   Trade.SetTypeFillingBySymbol(_Symbol);
   Trade.SetAsyncMode(false);

   g_gv_prefix = "G5X5_" + IntegerToString((int)InpMagicNumber) + "_" + _Symbol + "_";
   RestorePersistentState();
   if(g_run_start <= 0)
      g_run_start = TimeCurrent();

   if(HasOwnedExposure())
   {
      datetime earliest = EarliestOwnedExposureTime();
      if(g_campaign_start <= 0)
         g_campaign_start = earliest;
      if(g_run_start <= 0 || g_run_start > earliest)
         g_run_start = earliest;
      g_campaign_active = true;
   }
   else if(!g_local_stopped)
   {
      g_campaign_start = 0;
      g_campaign_profit_armed = false;
   }

   g_run_realized = ClosedProfitSince(g_run_start);
   g_campaign_realized = g_campaign_start > 0 ? ClosedProfitSince(g_campaign_start) : 0.0;
   g_session_id = StringFormat("%I64d-%I64d-%u", (long)AccountInfoInteger(ACCOUNT_LOGIN),
                               (long)TimeLocal(), GetTickCount());
   SavePersistentState();

   if(g_testing || !InpUseRailway)
   {
      g_profit_target = InpTesterOverallProfitTarget;
      g_max_loss = InpTesterMaximumLoss;
      g_campaign_target = InpCampaignTargetMoney;
      g_registered = true;
      g_remote_enabled = !g_local_stopped;
      g_status = g_local_stopped ? "OFF" : "RUNNING";
   }
   else if(!g_local_stopped)
      RegisterRemoteSession();
   else
      g_status = "OFF";

   EventSetTimer(MathMax(1, InpRailwayPollSeconds));
   return INIT_SUCCEEDED;
}


void OnDeinit(const int reason)
{
   EventKillTimer();
   SavePersistentState();
   if(reason == REASON_REMOVE)
      DeletePersistentState();
}


void OnTradeTransaction(const MqlTradeTransaction &transaction,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(transaction.type != TRADE_TRANSACTION_DEAL_ADD || transaction.deal == 0)
      return;
   if(!HistoryDealSelect(transaction.deal))
      return;
   if(HistoryDealGetString(transaction.deal, DEAL_SYMBOL) != _Symbol ||
      HistoryDealGetInteger(transaction.deal, DEAL_MAGIC) != InpMagicNumber)
      return;

   double amount = HistoryDealGetDouble(transaction.deal, DEAL_PROFIT) +
                   HistoryDealGetDouble(transaction.deal, DEAL_COMMISSION) +
                   HistoryDealGetDouble(transaction.deal, DEAL_SWAP) +
                   HistoryDealGetDouble(transaction.deal, DEAL_FEE);
   datetime deal_time = (datetime)HistoryDealGetInteger(transaction.deal, DEAL_TIME);
   if(deal_time >= g_run_start)
      g_run_realized += amount;
   if(g_campaign_start > 0 && deal_time >= g_campaign_start)
      g_campaign_realized += amount;
}


void OnTimer()
{
   if(!InpUseRailway || g_testing)
      return;

   if(g_stopping)
      ContinueStop();
   if(g_campaign_closing)
      ContinueCampaignClose();

   if(g_local_stopped)
   {
      SendTelemetry();
      return;
   }
   if(!g_registered)
      RegisterRemoteSession();
   else
   {
      FetchRemoteConfig();
      SendTelemetry();
   }
}


void OnTick()
{
   if(g_stopping)
   {
      ContinueStop();
      return;
   }
   if(g_local_stopped)
      return;

   if(InpUseRailway && !g_testing)
   {
      if(!g_registered || !g_remote_enabled)
         return;
      if(g_last_server_contact > 0 && InpRemoteFailSafeSeconds > 0 &&
         TimeLocal() - g_last_server_contact > InpRemoteFailSafeSeconds)
      {
         BeginStop("ERROR", "Railway connection lost; fail-safe stopped the bot");
         return;
      }
   }

   if(g_campaign_closing)
   {
      ContinueCampaignClose();
      return;
   }

   if(!g_campaign_active)
   {
      StartCampaign();
      return;
   }

   ManageLadderBreakeven();

   double run_profit = RunProfit();
   double campaign_profit = CampaignProfit();

   if(g_profit_target > 0.0 && run_profit >= g_profit_target)
   {
      BeginStop("PROFIT_TARGET_REACHED", "Overall profit target reached; bot stopped");
      return;
   }
   if(g_max_loss > 0.0 && run_profit <= -g_max_loss)
   {
      BeginStop("MAX_LOSS_REACHED", "Maximum loss reached; bot stopped");
      return;
   }
   if(campaign_profit >= g_campaign_target)
   {
      BeginCampaignClose("CAMPAIGN_COMPLETE");
      return;
   }

   if(!g_campaign_profit_armed && campaign_profit > 0.0)
   {
      g_campaign_profit_armed = true;
      SavePersistentState();
      SetEvent("CAMPAIGN_PROTECTED", "Campaign " + IntegerToString(g_campaign_number) +
               " entered profit; $0 campaign floor armed");
   }
   else if(g_campaign_profit_armed && campaign_profit <= 0.0)
   {
      BeginCampaignClose("CAMPAIGN_BREAKEVEN");
      return;
   }
}
