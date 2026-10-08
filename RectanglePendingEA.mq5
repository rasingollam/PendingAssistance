#property strict
#property version   "2.01"
#property description "Cached rectangle entries with market execution, configurable RR and partial profit."
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
   bool   upper;
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
#include "VirtualEntryMath.mqh"
#include "VirtualTrades.mqh"
#include "RectanglePanel.mqh"

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

void SyncRectangles()
{
   for(int i=ArraySize(rectangles)-1; i>=0; i--)
   {
      if(IsRectangle(rectangles[i].name))
         continue;
      CancelVirtualPlan(i,"Rectangle deleted");
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
      string selection_key=RectangleTradeKey(index)+".Upper";
      rectangles[index].upper=!GlobalVariableCheck(selection_key) || GlobalVariableGet(selection_key)==1;
   }
   for(int i=0; i<ArraySize(rectangles); i++)
      PositionButtons(i);
   SyncVirtualLevels();
   ChartRedraw(0);
}

double TickPrice(const double price,const double tick_size)
{
   return NormalizeDouble(MathRound(price/tick_size)*tick_size,_Digits);
}

bool RiskVolume(const bool buy,const double entry,const double sl,
                double &volume,double &estimated_loss,const double risk_budget=0)
{
   double budget=risk_budget>0 ? risk_budget : RiskMoney;
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
   double raw_volume=budget/(-profit)*minimum;
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
   if(estimated_loss>budget+1e-8)
   {
      volume=NormalizeDouble(volume-step,8);
      if(volume<minimum-1e-10 ||
         !OrderCalcProfit(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
                          _Symbol,volume,entry,sl,profit) || profit>=0 || -profit>budget+1e-8)
      {
         ReportError("No valid lot size fits your risk budget.");
         return false;
      }
      estimated_loss=-profit;
   }
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
   ProcessVirtualEntries();
   ManagePartialProfit();
   SyncRectangles();
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
         for(int action=0; action<5; action++)
            if(sparam==ButtonName(rectangles[i].id,action))
            {
               ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
               if(action==4)
               {
                  CancelVirtualPlan(i,"Cancelled with the panel");
                  SyncRectangles();
                  SyncPartialMarkers();
                  return;
               }
               if(!IsRectangle(rectangles[i].name) || HasVirtualPlan(i) || RectangleHasTrade(i) ||
                  !ObjectGetInteger(0,rectangles[i].name,OBJPROP_SELECTED))
               {
                  SyncRectangles();
                  return;
               }
               if(action<2)
               {
                  rectangles[i].upper=action==0;
                  GlobalVariableSet(RectangleTradeKey(i)+".Upper",action==0 ? 1 : 0);
                  PositionButtons(i);
                  ChartRedraw(0);
               }
               else ArmRectangleTrade(i,action==2);
               return;
            }
   }
   if(id==CHARTEVENT_OBJECT_DELETE)
   {
      // Process rectangle deletion immediately, including delete/recreate with the same name.
      for(int i=ArraySize(rectangles)-1; i>=0; i--)
         if(rectangles[i].name==sparam)
         {
            CancelVirtualPlan(i,"Rectangle deleted");
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
