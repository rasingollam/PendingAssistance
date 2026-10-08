#property strict
#property version   "1.21"
#property description "Rectangle pending orders with configurable RR and one-time partial profit."
#property description "RiskMoney is in account currency. Deinitialization preserves chart rectangles."

input double RiskMoney = 20.0; // Maximum estimated SL loss in account currency (excluding fees)
input double RR = 2.0; // Reward/risk: SL stays one rectangle height away; TP extends to RR
input bool IsPartialProfit = true; // Partially close open positions at the configured R level
input double PartialLevelRR = 1.0; // Partial trigger as a multiple of the initial SL distance
input double PartialPercentage = 60.0; // Volume to close, 50 to 80 percent
input bool IsBEAfterPartial = true; // Move the remaining position's SL to entry after the partial

const ulong MAGIC = 2026100601;
const string PREFIX = "__RectanglePendingEA_";

struct RectangleState
{
   string name;
   int    id;
   bool   submitted;
};
RectangleState rectangles[];
int next_id = 0;
bool old_create_events = false;
bool old_delete_events = false;
bool old_mouse_move_events = false;
bool initialized = false;

#include "PartialProfit.mqh"
#include "PartialMarkers.mqh"
#include "RectangleTrades.mqh"

string ButtonName(const int id,const int action)
{
   return PREFIX + IntegerToString(id) + "_" + IntegerToString(action);
}

void RemoveButtons(const int id)
{
   for(int action=0; action<3; action++)
      ObjectDelete(0,ButtonName(id,action));
}

void ReportError(const string message)
{
   Print("RectanglePendingEA: ",message);
   Alert("RectanglePendingEA: ",message);
}

bool IsRectangle(const string name)
{
   return ObjectFind(0,name)==0 &&
          (ENUM_OBJECT)ObjectGetInteger(0,name,OBJPROP_TYPE)==OBJ_RECTANGLE;
}

void DrawButton(const int id,const int action,const int x,const int y,
                const int width,const int height)
{
   string name=ButtonName(id,action);
   if(ObjectFind(0,name)<0 && !ObjectCreate(0,name,OBJ_BUTTON,0,0,0))
      return;
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,width);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,height);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,
                    action==0 ? clrSeaGreen : (action==1 ? clrFireBrick : clrDimGray));
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,clrBlack);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,height>=20 && width>=42 ? 9 : 7);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,100);
   ObjectSetString(0,name,OBJPROP_FONT,"Arial");
   ObjectSetString(0,name,OBJPROP_TEXT,action==0 ? "Buy" : (action==1 ? "Sell" : "Close"));
   ObjectSetString(0,name,OBJPROP_TOOLTIP,
                   action==2 ? "Delete this rectangle (orders are kept)" :
                   "Place a pending order using this rectangle and the RR input");
}

void PositionButtons(const int index)
{
   string name=rectangles[index].name;
   if(!IsRectangle(name) || RectangleHasTrade(index) ||
      !ObjectGetInteger(0,name,OBJPROP_SELECTED))
   {
      RemoveButtons(rectangles[index].id);
      return;
   }
   int x1,y1,x2,y2;
   datetime t1=(datetime)ObjectGetInteger(0,name,OBJPROP_TIME,0);
   datetime t2=(datetime)ObjectGetInteger(0,name,OBJPROP_TIME,1);
   double p1=ObjectGetDouble(0,name,OBJPROP_PRICE,0);
   double p2=ObjectGetDouble(0,name,OBJPROP_PRICE,1);
   if(!ChartTimePriceToXY(0,0,t1,p1,x1,y1) ||
      !ChartTimePriceToXY(0,0,t2,p2,x2,y2))
   {
      RemoveButtons(rectangles[index].id);
      return;
   }
   int chart_width=(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
   int chart_height=(int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS,0);
   // Controls are shown only for selected rectangles, inset from selection handles.
   int padding=8;
   int left=(int)MathMax(0,MathMin(x1,x2))+padding;
   int right=(int)MathMin(chart_width,MathMax(x1,x2))-padding;
   int top=(int)MathMax(0,MathMin(y1,y2))+padding;
   int bottom=(int)MathMin(chart_height,MathMax(y1,y2))-padding;
   int available_width=right-left;
   int available_height=bottom-top;
   // Keep every button within the visible rectangle. Enlarge tiny rectangles to show controls.
   if(available_width<90 || available_height<16)
   {
      RemoveButtons(rectangles[index].id);
      return;
   }
   int gap=2;
   int width=(int)MathMin(56,(available_width-2*gap)/3);
   int height=(int)MathMin(22,available_height);
   int start_x=left+(available_width-(3*width+2*gap))/2;
   int start_y=top+(available_height-height)/2;
   for(int action=0; action<3; action++)
      DrawButton(rectangles[index].id,action,start_x+action*(width+gap),start_y,width,height);
}

void SyncRectangles()
{
   for(int i=ArraySize(rectangles)-1; i>=0; i--)
   {
      if(IsRectangle(rectangles[i].name))
         continue;
      RemoveButtons(rectangles[i].id);
      int count=ArraySize(rectangles);
      for(int j=i; j<count-1; j++)
         rectangles[j]=rectangles[j+1];
      ArrayResize(rectangles,count-1);
   }
   int total=ObjectsTotal(0,0,OBJ_RECTANGLE);
   for(int i=0; i<total; i++)
   {
      string name=ObjectName(0,i,0,OBJ_RECTANGLE);
      bool known=false;
      for(int j=0; j<ArraySize(rectangles); j++)
         if(rectangles[j].name==name) { known=true; break; }
      if(known || name=="")
         continue;
      int index=ArraySize(rectangles);
      ArrayResize(rectangles,index+1);
      rectangles[index].name=name;
      rectangles[index].id=next_id++;
      rectangles[index].submitted=false;
   }
   for(int i=0; i<ArraySize(rectangles); i++)
      PositionButtons(i);
   ChartRedraw(0);
}

double TickPrice(const double price,const double tick_size)
{
   return NormalizeDouble(MathRound(price/tick_size)*tick_size,_Digits);
}

bool RiskVolume(const bool buy,const double entry,const double sl,
                double &volume,double &estimated_loss)
{
   double minimum=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maximum=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(minimum<=0 || maximum<minimum || step<=0)
   {
      ReportError("Invalid broker volume settings.");
      return false;
   }
   double profit=0;
   if(!OrderCalcProfit(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
                       _Symbol,minimum,entry,sl,profit) || profit>=0)
   {
      ReportError("Cannot calculate the SL risk. Error "+IntegerToString(GetLastError()));
      return false;
   }
   double raw_volume=RiskMoney/(-profit)*minimum;
   volume=NormalizeDouble(MathFloor(MathMin(raw_volume,maximum)/step)*step,8);
   if(volume<minimum-1e-10)
   {
      ReportError("The minimum lot size exceeds your risk budget. Minimum estimated loss: "+
                  DoubleToString(-profit,2)+" "+AccountInfoString(ACCOUNT_CURRENCY));
      return false;
   }
   if(!OrderCalcProfit(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
                       _Symbol,volume,entry,sl,profit) || profit>=0)
   {
      ReportError("Cannot verify the selected volume's risk.");
      return false;
   }
   estimated_loss=-profit;
   // Final verification prevents rounding the risk upward.
   if(estimated_loss>RiskMoney+1e-8)
   {
      volume=NormalizeDouble(volume-step,8);
      if(volume<minimum-1e-10 ||
         !OrderCalcProfit(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
                          _Symbol,volume,entry,sl,profit) || profit>=0 || -profit>RiskMoney+1e-8)
      {
         ReportError("No valid lot size fits your risk budget.");
         return false;
      }
      estimated_loss=-profit;
   }
   return true;
}

bool PlaceRectangleOrder(const int index,const bool buy)
{
   if(!IsRectangle(rectangles[index].name) || RectangleHasTrade(index))
      return false;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   {
      ReportError("Enable Algo Trading and allow EA trading on this account.");
      return false;
   }
   MqlTick quote={};
   if(!SymbolInfoTick(_Symbol,quote) || quote.ask<=0 || quote.bid<=0)
   {
      ReportError("No valid current Bid/Ask quote.");
      return false;
   }
   double tick_size=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tick_size<=0) { ReportError("Invalid symbol tick size."); return false; }
   double p1=ObjectGetDouble(0,rectangles[index].name,OBJPROP_PRICE,0);
   double p2=ObjectGetDouble(0,rectangles[index].name,OBJPROP_PRICE,1);
   double bottom=TickPrice(MathMin(p1,p2),tick_size);
   double top=TickPrice(MathMax(p1,p2),tick_size);
   double height=top-bottom;
   if(height<tick_size*0.5) { ReportError("Rectangle has no usable price height."); return false; }
   double current=buy ? quote.ask : quote.bid;
   double stop_entry=buy ? bottom : top;
   if(MathAbs(stop_entry-current)<tick_size*1e-6)
   {
      ReportError("Entry equals the current quote. Move the rectangle to select a stop or limit.");
      return false;
   }
   bool is_limit=buy ? stop_entry<current : stop_entry>current;
   bool within_rectangle=current>=bottom && current<=top;
   double inside_entry=buy ? bottom : top;
   double outside_limit_entry=buy ? top : bottom;
   double limit_entry=within_rectangle ? inside_entry : outside_limit_entry;
   double entry=is_limit ? limit_entry : stop_entry;
   bool valid_limit=buy ? entry<current : entry>current;
   if(is_limit && !valid_limit)
   {
      ReportError("Limit entry must be below Ask for buys or above Bid for sells.");
      return false;
   }
   ENUM_ORDER_TYPE type=buy ? (is_limit ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_BUY_STOP)
                            : (is_limit ? ORDER_TYPE_SELL_LIMIT : ORDER_TYPE_SELL_STOP);
   double tp=TickPrice(buy ? entry+height*RR : entry-height*RR,tick_size);
   double stop_sl=TickPrice(buy ? entry-height : entry+height,tick_size);
   double outside_limit_sl=buy ? bottom : top;
   double limit_sl=within_rectangle ? stop_sl : outside_limit_sl;
   double sl=is_limit ? limit_sl : stop_sl;
   if(sl<=0 || entry<=0 || tp<=0) { ReportError("Rectangle produces invalid prices."); return false; }
   if((buy && sl>=entry) || (!buy && sl<=entry))
   {
      ReportError("Rectangle produces an SL distance smaller than the tradable tick size.");
      return false;
   }
   double actual_rr=MathAbs(tp-entry)/MathAbs(entry-sl);
   if(IsPartialProfit && PartialLevelRR>=actual_rr-1e-8)
   {
      ReportError("PartialLevelRR must be below this order's actual TP RR after tick rounding.");
      return false;
   }
   double stops_distance=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   double tolerance=tick_size*1e-6;
   if(MathAbs(entry-current)+tolerance<stops_distance ||
      MathAbs(entry-sl)+tolerance<stops_distance || MathAbs(tp-entry)+tolerance<stops_distance)
   {
      ReportError("Entry, SL or TP is too close for the broker's minimum stop distance.");
      return false;
   }
   double volume=0,loss=0;
   if(!RiskVolume(buy,entry,sl,volume,loss)) return false;
   MqlTradeRequest request={};
   MqlTradeCheckResult check={};
   MqlTradeResult result={};
   request.action=TRADE_ACTION_PENDING;
   request.magic=MAGIC;
   request.symbol=_Symbol;
   request.volume=volume;
   request.type=type;
   request.price=entry;
   request.sl=sl;
   request.tp=tp;
   request.type_filling=ORDER_FILLING_RETURN;
   request.type_time=ORDER_TIME_GTC;
   request.comment=RectangleTradeTag(index);
   ResetLastError();
   if(!OrderCheck(request,check))
   {
      ReportError("Order check failed: "+check.comment+" ("+IntegerToString((int)check.retcode)+
                  "), error "+IntegerToString(GetLastError()));
      return false;
   }
   ResetLastError();
   MarkRectangleUncertain(index,true);
   bool sent=OrderSend(request,result);
   if(!sent || (result.retcode!=TRADE_RETCODE_DONE && result.retcode!=TRADE_RETCODE_PLACED))
   {
      // A timeout may have reached the server. Prevent a second click from duplicating it.
      if(result.retcode==TRADE_RETCODE_TIMEOUT)
      {
         rectangles[index].submitted=true;
         RemoveButtons(rectangles[index].id);
         ReportError("Order timed out. Controls removed to prevent duplicate orders. Check Trade/History.");
      }
      else
      {
         MarkRectangleUncertain(index,false);
         ReportError("Order failed: "+result.comment+" ("+IntegerToString((int)result.retcode)+
                     "), error "+IntegerToString(GetLastError()));
      }
      return false;
   }
   rectangles[index].submitted=true;
   LinkRectangleOrder(index,result.order);
   RemoveButtons(rectangles[index].id);
   SyncPartialMarkers();
   PrintFormat("RectanglePendingEA: %s order #%I64u, lots %.8f, entry %.*f, SL %.*f, TP %.*f, estimated loss %.2f %s",
               EnumToString(type),result.order,volume,_Digits,entry,_Digits,sl,_Digits,tp,
               loss,AccountInfoString(ACCOUNT_CURRENCY));
   ChartRedraw(0);
   return true;
}

int OnInit()
{
   if(!MathIsValidNumber(RiskMoney) || RiskMoney<=0)
   {
      Print("RectanglePendingEA: RiskMoney must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(!MathIsValidNumber(RR) || RR<=0 ||
      !MathIsValidNumber(PartialLevelRR) || PartialLevelRR<=0 ||
      !MathIsValidNumber(PartialPercentage) || PartialPercentage<50 || PartialPercentage>80 ||
      (IsPartialProfit && PartialLevelRR>=RR))
   {
      Print("RectanglePendingEA: RR and PartialLevelRR must be positive; percentage must be 50..80; ",
            "enabled partial level must be below RR.");
      return INIT_PARAMETERS_INCORRECT;
   }
   old_create_events=(bool)ChartGetInteger(0,CHART_EVENT_OBJECT_CREATE);
   old_delete_events=(bool)ChartGetInteger(0,CHART_EVENT_OBJECT_DELETE);
   old_mouse_move_events=(bool)ChartGetInteger(0,CHART_EVENT_MOUSE_MOVE);
   ChartSetInteger(0,CHART_EVENT_OBJECT_CREATE,true);
   ChartSetInteger(0,CHART_EVENT_OBJECT_DELETE,true);
   ChartSetInteger(0,CHART_EVENT_MOUSE_MOVE,true);
   if(!EventSetMillisecondTimer(250))
   {
      ChartSetInteger(0,CHART_EVENT_OBJECT_CREATE,old_create_events);
      ChartSetInteger(0,CHART_EVENT_OBJECT_DELETE,old_delete_events);
      ChartSetInteger(0,CHART_EVENT_MOUSE_MOVE,old_mouse_move_events);
      return INIT_FAILED;
   }
   initialized=true;
   ObjectsDeleteAll(0,PREFIX);
   PreparePartialManagement();
   SyncRectangles();
   SyncPartialMarkers();
   Print("RectanglePendingEA ready. Risk: ",DoubleToString(RiskMoney,2)," ",
         AccountInfoString(ACCOUNT_CURRENCY),". Deinitialization preserves chart rectangles.");
   return INIT_SUCCEEDED;
}

void OnTimer()
{
   SyncRectangles();
   ManagePartialProfit();
   SyncPartialMarkers();
}

void OnTick()
{
   ManagePartialProfit();
   SyncPartialMarkers();
}

void OnTradeTransaction(const MqlTradeTransaction &transaction,
                        const MqlTradeRequest &request,const MqlTradeResult &result)
{
   if(initialized)
   {
      SyncRectangles();
      SyncPartialMarkers();
   }
}

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(id==CHARTEVENT_MOUSE_MOVE)
   {
      // Reposition during a selected rectangle's drag instead of waiting for drag release.
      if(((int)StringToInteger(sparam)&1)!=0)
      {
         bool moved=false;
         for(int i=0; i<ArraySize(rectangles); i++)
            if(IsRectangle(rectangles[i].name))
            {
               PositionButtons(i);
               moved=true;
            }
         if(moved) ChartRedraw(0);
      }
      return;
   }
   if(id==CHARTEVENT_OBJECT_CLICK)
   {
      for(int i=0; i<ArraySize(rectangles); i++)
         for(int action=0; action<3; action++)
            if(sparam==ButtonName(rectangles[i].id,action))
            {
               // Ignore queued button clicks after the rectangle has been deselected.
               if(!IsRectangle(rectangles[i].name) ||
                  RectangleHasTrade(i) ||
                  !ObjectGetInteger(0,rectangles[i].name,OBJPROP_SELECTED))
               {
                  RemoveButtons(rectangles[i].id);
                  ChartRedraw(0);
                  return;
               }
               ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
               if(action==2)
               {
                  ObjectDelete(0,rectangles[i].name);
                  RemoveButtons(rectangles[i].id);
                  SyncRectangles();
               }
               else
                  PlaceRectangleOrder(i,action==0);
               return;
            }
   }
   if(id==CHARTEVENT_OBJECT_DELETE)
   {
      // Process rectangle deletion immediately, including delete/recreate with the same name.
      for(int i=ArraySize(rectangles)-1; i>=0; i--)
         if(rectangles[i].name==sparam)
         {
            RemoveButtons(rectangles[i].id);
            int count=ArraySize(rectangles);
            for(int j=i; j<count-1; j++) rectangles[j]=rectangles[j+1];
            ArrayResize(rectangles,count-1);
            break;
         }
   }
   if(id==CHARTEVENT_CLICK || id==CHARTEVENT_OBJECT_CLICK ||
      id==CHARTEVENT_CHART_CHANGE || id==CHARTEVENT_OBJECT_DRAG ||
      id==CHARTEVENT_OBJECT_CHANGE ||
      (id==CHARTEVENT_OBJECT_CREATE && IsRectangle(sparam)))
      SyncRectangles();
   if(id==CHARTEVENT_CHART_CHANGE) SyncPartialMarkers();
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(!initialized) return;
   ObjectsDeleteAll(0,PREFIX);
   ChartSetInteger(0,CHART_EVENT_OBJECT_CREATE,old_create_events);
   ChartSetInteger(0,CHART_EVENT_OBJECT_DELETE,old_delete_events);
   ChartSetInteger(0,CHART_EVENT_MOUSE_MOVE,old_mouse_move_events);
   ChartRedraw(0);
}
