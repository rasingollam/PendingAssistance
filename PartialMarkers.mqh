// Ash dash-dot level with an above-left label for each EA pending order/open position.
const string MARKER_PREFIX = "__RectanglePendingEA_Partial_";

double PartialMarkerLevel(const bool buy,const double entry,const double risk)
{
   return buy ? entry+risk*PartialLevelRR : entry-risk*PartialLevelRR;
}

void KeepMarker(string &names[],const string name)
{
   int size=ArraySize(names);
   ArrayResize(names,size+1);
   names[size]=name;
}

bool MarkerProfit(const bool buy,const double lots,const double entry,const double level,double &money)
{
   return lots>0 && OrderCalcProfit(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
                                   _Symbol,lots,entry,level,money);
}

void DrawPartialMarker(const string identity,const ulong ticket,const double level,
                       const double lots,const double money,string &keep[])
{
   string line=MARKER_PREFIX+identity;
   string label=line+"_Text";
   if(ObjectFind(0,line)<0 && !ObjectCreate(0,line,OBJ_HLINE,0,0,level)) return;
   ObjectSetDouble(0,line,OBJPROP_PRICE,level);
   ObjectSetInteger(0,line,OBJPROP_COLOR,clrDarkGray);
   ObjectSetInteger(0,line,OBJPROP_STYLE,STYLE_DASHDOT);
   ObjectSetInteger(0,line,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,line,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,line,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,line,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,line,OBJPROP_BACK,true);
   string text="PR "+DoubleToString(lots,2)+" "+DoubleToString(money,2);
   string reference=ticket>0 ? " #"+IntegerToString((long)ticket) : " waiting trade";
   string tooltip=text+" "+AccountInfoString(ACCOUNT_CURRENCY)+reference+" estimated partial profit";
   ObjectSetString(0,line,OBJPROP_TOOLTIP,tooltip);
   KeepMarker(keep,line);
   int x,y;
   int chart_height=(int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS,0);
   if(!ChartTimePriceToXY(0,0,iTime(_Symbol,_Period,0),level,x,y) || y<20 || y>=chart_height)
   {
      ObjectDelete(0,label); // Offscreen levels must not leave floating labels on the chart.
      return;
   }
   if(ObjectFind(0,label)<0 && !ObjectCreate(0,label,OBJ_LABEL,0,0,0)) return;
   ObjectSetInteger(0,label,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,label,OBJPROP_ANCHOR,ANCHOR_LEFT_LOWER);
   // Match the inset and compact size of the native TP/SL captions in the reference chart.
   ObjectSetInteger(0,label,OBJPROP_XDISTANCE,7);
   ObjectSetInteger(0,label,OBJPROP_YDISTANCE,y-1);
   ObjectSetInteger(0,label,OBJPROP_COLOR,clrDarkGray);
   ObjectSetInteger(0,label,OBJPROP_FONTSIZE,7);
   ObjectSetInteger(0,label,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,label,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,label,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,label,OBJPROP_BACK,false);
   ObjectSetString(0,label,OBJPROP_FONT,"Arial");
   ObjectSetString(0,label,OBJPROP_TEXT,text);
   ObjectSetString(0,label,OBJPROP_TOOLTIP,tooltip);
   KeepMarker(keep,label);
}

void PendingPartialMarker(const ulong ticket,string &keep[])
{
   if(!OrderSelect(ticket) || OrderGetString(ORDER_SYMBOL)!=_Symbol ||
      (ulong)OrderGetInteger(ORDER_MAGIC)!=MAGIC) return;
   ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
   bool buy=type==ORDER_TYPE_BUY_LIMIT || type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_BUY_STOP_LIMIT;
   bool sell=type==ORDER_TYPE_SELL_LIMIT || type==ORDER_TYPE_SELL_STOP || type==ORDER_TYPE_SELL_STOP_LIMIT;
   if(!buy && !sell) return;
   double entry=OrderGetDouble(ORDER_PRICE_OPEN);
   double sl=OrderGetDouble(ORDER_SL);
   double risk=buy ? entry-sl : sl-entry;
   if(sl<=0 || risk<=0) return;
   double level=PartialMarkerLevel(buy,entry,risk);
   double tp=OrderGetDouble(ORDER_TP);
   if(tp>0 && (buy ? tp-entry : entry-tp)<=risk*PartialLevelRR) return;
   double volume=OrderGetDouble(ORDER_VOLUME_CURRENT);
   double lots=PartialCloseVolume(volume,volume,PartialPercentage,
                                 SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),
                                 SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),
                                 SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP));
   double money=0;
   if(!MarkerProfit(buy,lots,entry,level,money)) return;
   DrawPartialMarker("O_"+IntegerToString((long)ticket),ticket,level,lots,money,keep);
}

void OpenPartialMarker(const ulong ticket,string &keep[])
{
   if(!PositionSelectByTicket(ticket) || PositionGetString(POSITION_SYMBOL)!=_Symbol ||
      (ulong)PositionGetInteger(POSITION_MAGIC)!=MAGIC) return;
   ulong identifier=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
   double initial_sl=0;
   bool history_done=false;
   long generation=0;
   if(!PartialHistory(identifier,initial_sl,history_done,generation) || !PositionSelectByTicket(ticket)) return;
   bool buy=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY;
   double current_entry=PositionGetDouble(POSITION_PRICE_OPEN);
   double current_volume=PositionGetDouble(POSITION_VOLUME);
   string key=partial_scope+IntegerToString((long)identifier)+"."+IntegerToString(generation);
   double entry=GlobalVariableCheck(key+".E") ? GlobalVariableGet(key+".E") : current_entry;
   if(initial_sl<=0) initial_sl=PositionGetDouble(POSITION_SL);
   double risk=GlobalVariableCheck(key+".R") ? GlobalVariableGet(key+".R") :
               (buy ? entry-initial_sl : initial_sl-entry);
   if(risk<=0 || (!GlobalVariableCheck(key+".R") && initial_sl<=0)) return;
   double level=PartialMarkerLevel(buy,entry,risk);
   bool completed=history_done || (GlobalVariableCheck(key+".S") && GlobalVariableGet(key+".S")==2);
   if(completed) return; // Pruning removes the line and label as soon as the partial is taken.
   double lots=0,money=0;
   double original=GlobalVariableCheck(key+".V") ? GlobalVariableGet(key+".V") : current_volume;
   if(MathAbs(current_entry-entry)>_Point*0.1 || current_volume>original+1e-10) return;
   double tp=PositionGetDouble(POSITION_TP);
   if(tp>0 && (buy ? tp-entry : entry-tp)<=risk*PartialLevelRR) return;
   lots=PartialCloseVolume(original,current_volume,PartialPercentage,
                          SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),
                          SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),
                          SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP));
   if(!MarkerProfit(buy,lots,entry,level,money)) return;
   DrawPartialMarker("P_"+IntegerToString((long)identifier),ticket,level,lots,money,keep);
}

void SyncPartialMarkers()
{
   if(!initialized) return;
   string keep[];
   if(IsPartialProfit)
   {
      for(int i=0; i<ArraySize(rectangles); i++)
         if(IsRectangle(rectangles[i].name)) VirtualPartialMarker(i,keep);
      for(int i=OrdersTotal()-1; i>=0; i--)
      {
         ulong ticket=OrderGetTicket(i);
         if(ticket!=0) PendingPartialMarker(ticket,keep);
      }
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         ulong ticket=PositionGetTicket(i);
         if(ticket!=0) OpenPartialMarker(ticket,keep);
      }
   }
   // Remove orphan markings on cancellation, expiry, full close or loss of eligibility.
   for(int i=ObjectsTotal(0,0,-1)-1; i>=0; i--)
   {
      string name=ObjectName(0,i,0,-1);
      if(StringFind(name,MARKER_PREFIX)!=0) continue;
      bool live=false;
      for(int j=0; j<ArraySize(keep); j++)
         if(keep[j]==name) { live=true; break; }
      if(!live) ObjectDelete(0,name);
   }
   ChartRedraw(0);
}
