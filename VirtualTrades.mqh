// Waiting market entries are snapshots saved in terminal globals, not broker pending orders.
struct VirtualPlan
{
   int state; // 0=none, 1=waiting, 2=sending, 3=uncertain
   bool buy;
   bool upper;
   bool rising;
   double entry;
   double sl;
   double tp;
   double lots;
   double risk_money;
   double estimated_loss;
   double reward_rr;
};

bool ReadVirtualPlan(const int index,VirtualPlan &plan)
{
   string key=RectangleTradeKey(index);
   plan.state=GlobalVariableCheck(key+".VState") ? (int)GlobalVariableGet(key+".VState") : 0;
   if(plan.state==0) return false;
   plan.buy=GlobalVariableGet(key+".VBuy")==1;
   plan.upper=GlobalVariableGet(key+".VUpper")==1;
   plan.rising=GlobalVariableGet(key+".VRise")==1;
   plan.entry=GlobalVariableGet(key+".VEntry");
   plan.sl=GlobalVariableGet(key+".VSL");
   plan.tp=GlobalVariableGet(key+".VTP");
   plan.lots=GlobalVariableGet(key+".VLots");
   plan.risk_money=GlobalVariableGet(key+".VRisk");
   plan.estimated_loss=GlobalVariableGet(key+".VLoss");
   plan.reward_rr=GlobalVariableGet(key+".VRR");
   return true;
}

void SetVirtualState(const int index,const int state)
{
   GlobalVariableSet(RectangleTradeKey(index)+".VState",state);
   GlobalVariablesFlush();
}

bool HasVirtualPlan(const int index)
{
   string key=RectangleTradeKey(index)+".VState";
   return GlobalVariableCheck(key) && GlobalVariableGet(key)!=0;
}

bool CancelVirtualPlan(const int index,const string reason="Cancelled")
{
   VirtualPlan plan;
   if(!ReadVirtualPlan(index,plan) || plan.state!=1) return false;
   // Atomically cancel only a still-waiting plan, never an in-flight market request.
   if(!GlobalVariableSetOnCondition(RectangleTradeKey(index)+".VState",0,1)) return false;
   GlobalVariablesFlush();
   Print("RectanglePendingEA: ",rectangles[index].name," - ",reason);
   return true;
}

bool NettingSymbolOccupied()
{
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      return false;
   for(int i=PositionsTotal()-1; i>=0; i--)
      if(PositionGetTicket(i)!=0 && PositionGetString(POSITION_SYMBOL)==_Symbol) return true;
   return false;
}

bool ArmRectangleTrade(const int index,const bool buy)
{
   if(!IsRectangle(rectangles[index].name) || HasVirtualPlan(index) || RectangleHasTrade(index)) return false;
   if(!PartialTradingAllowed()) { ReportError("Enable Algo Trading before arming a trade."); return false; }
   if(NettingSymbolOccupied())
   {
      ReportError("This netting account already has a position on this symbol. Close it before arming a separate trade.");
      return false;
   }
   MqlTick quote={};
   if(!SymbolInfoTick(_Symbol,quote) || quote.ask<=0 || quote.bid<=0) return false;
   double tick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tick<=0) return false;
   double p1=ObjectGetDouble(0,rectangles[index].name,OBJPROP_PRICE,0);
   double p2=ObjectGetDouble(0,rectangles[index].name,OBJPROP_PRICE,1);
   double bottom=TickPrice(MathMin(p1,p2),tick);
   double top=TickPrice(MathMax(p1,p2),tick);
   double height=top-bottom;
   double entry=SelectedEntryPrice(rectangles[index].upper,bottom,top);
   double sl=TickPrice(VirtualStopPrice(buy,entry,height),tick);
   double tp=TickPrice(VirtualTargetPrice(buy,entry,height,RR),tick);
   if(height<tick*0.5 || entry<=0 || sl<=0 || tp<=0)
   {
      ReportError("Rectangle produces invalid entry, SL or TP prices.");
      return false;
   }
   double current=buy ? quote.ask : quote.bid;
   double lots=0,loss=0;
   if(!RiskVolume(buy,entry,sl,lots,loss,RiskMoney)) return false;
   string key=RectangleTradeKey(index);
   GlobalVariableSet(key+".VBuy",buy ? 1 : 0);
   GlobalVariableSet(key+".VUpper",rectangles[index].upper ? 1 : 0);
   GlobalVariableSet(key+".VRise",entry>current ? 1 : 0);
   GlobalVariableSet(key+".VEntry",entry);
   GlobalVariableSet(key+".VSL",sl);
   GlobalVariableSet(key+".VTP",tp);
   GlobalVariableSet(key+".VLots",lots);
   GlobalVariableSet(key+".VRisk",RiskMoney);
   GlobalVariableSet(key+".VLoss",loss);
   GlobalVariableSet(key+".VRR",RR);
   // Publish state last, after all cached prices and sizing parameters have been saved.
   SetVirtualState(index,1);
   PrintFormat("RectanglePendingEA: %s %s waiting, entry %.*f, SL %.*f, TP %.*f, estimated lots %.8f.",
               rectangles[index].name,buy ? "BUY" : "SELL",_Digits,entry,_Digits,sl,_Digits,tp,lots);
   SyncRectangles();
   SyncPartialMarkers();
   return true;
}

void ProcessVirtualPlan(const int index)
{
   VirtualPlan plan;
   if(!ReadVirtualPlan(index,plan)) return;
   if(plan.state!=1)
   {
      // Recover after a delayed response or restart without resending the market request.
      ulong recovered=RecoverRectangleOrder(index);
      if(recovered!=0)
      {
         LinkRectangleOrder(index,recovered);
         SetVirtualState(index,0);
      }
      return;
   }
   if(RectangleHasTrade(index))
   {
      CancelVirtualPlan(index,"A linked trade is already active");
      return;
   }
   MqlTick quote={};
   if(!SymbolInfoTick(_Symbol,quote) || quote.ask<=0 || quote.bid<=0) return;
   double current=plan.buy ? quote.ask : quote.bid;
   if(!VirtualEntryReached(plan.rising,current,plan.entry)) return;
   double tick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tick<=0) return;
   double spread=LiveEntrySpread(quote.ask,quote.bid);
   if(!VirtualEntryAllowed(current,plan.entry,spread,tick*1e-6))
   {
      CancelVirtualPlan(index,"Entry missed: quote distance exceeded the live spread");
      return;
   }
   if(!PartialTradingAllowed()) { CancelVirtualPlan(index,"Trading unavailable at the trigger"); return; }
   if(NettingSymbolOccupied()) { CancelVirtualPlan(index,"A position already exists on this netting symbol"); return; }
   double risk=plan.buy ? current-plan.sl : plan.sl-current;
   if(risk<=0) { CancelVirtualPlan(index,"Quote is beyond the planned SL"); return; }
   double tp=TickPrice(VirtualTargetPrice(plan.buy,current,risk,plan.reward_rr),tick);
   double stops=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   double exit_quote=plan.buy ? quote.bid : quote.ask;
   double sl_distance=plan.buy ? exit_quote-plan.sl : plan.sl-exit_quote;
   double tp_distance=plan.buy ? tp-exit_quote : exit_quote-tp;
   if(tp<=0 || sl_distance<=0 || tp_distance<=0 ||
      sl_distance+tick*1e-6<stops || tp_distance+tick*1e-6<stops)
   {
      CancelVirtualPlan(index,"Broker stop-distance rules do not allow the cached SL/TP");
      return;
   }
   double lots=0,loss=0;
   if(!RiskVolume(plan.buy,current,plan.sl,lots,loss,plan.risk_money))
   {
      CancelVirtualPlan(index,"No valid market volume fits the risk budget");
      return;
   }
   MqlTradeRequest request={};
   MqlTradeCheckResult check={};
   MqlTradeResult result={};
   request.action=TRADE_ACTION_DEAL;
   request.magic=MAGIC;
   request.symbol=_Symbol;
   request.type=plan.buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price=current;
   request.volume=lots;
   request.sl=plan.sl;
   request.tp=tp;
   request.deviation=(ulong)MathFloor(spread/_Point+1e-8);
   request.comment=RectangleTradeTag(index);
   if(!PartialFilling(request.type_filling) || !OrderCheck(request,check))
   {
      CancelVirtualPlan(index,"Market order check failed: "+check.comment);
      return;
   }
   // One last quote check immediately before claiming the saved plan and sending.
   MqlTick latest={};
   if(!SymbolInfoTick(_Symbol,latest) || latest.ask<=0 || latest.bid<=0) return;
   double latest_price=plan.buy ? latest.ask : latest.bid;
   double latest_spread=LiveEntrySpread(latest.ask,latest.bid);
   if(!VirtualEntryAllowed(latest_price,plan.entry,latest_spread,tick*1e-6))
   {
      CancelVirtualPlan(index,"Entry distance exceeded the refreshed live spread before submission");
      return;
   }
   if(MathAbs(latest_price-current)>tick*1e-6) return; // Rebuild price/risk sizing on the next tick.
   request.deviation=(ulong)MathFloor(latest_spread/_Point+1e-8);
   if(!GlobalVariableSetOnCondition(RectangleTradeKey(index)+".VState",2,1)) return;
   MarkRectangleUncertain(index,true);
   bool sent=OrderSend(request,result);
   if(sent && (result.retcode==TRADE_RETCODE_DONE || result.retcode==TRADE_RETCODE_DONE_PARTIAL ||
               result.retcode==TRADE_RETCODE_PLACED))
   {
      ulong order=result.order;
      if(order==0 && result.deal!=0 && HistoryDealSelect(result.deal))
         order=(ulong)HistoryDealGetInteger(result.deal,DEAL_ORDER);
      if(order!=0)
      {
         LinkRectangleOrder(index,order);
         SetVirtualState(index,0);
      }
      else SetVirtualState(index,3);
      PrintFormat("RectanglePendingEA: market %s #%I64u, requested %.*f, filled %.*f, lots %.8f, SL %.*f, TP %.*f.",
                  plan.buy ? "BUY" : "SELL",order,_Digits,current,_Digits,result.price,
                  result.volume,_Digits,plan.sl,_Digits,tp);
   }
   else if(result.retcode==TRADE_RETCODE_TIMEOUT || result.retcode==TRADE_RETCODE_CONNECTION || result.retcode==0)
   {
      SetVirtualState(index,3);
      Print("RectanglePendingEA: uncertain market outcome for ",rectangles[index].name,
            ". Check Trade/History; no automatic resend.");
   }
   else
   {
      MarkRectangleUncertain(index,false);
      SetVirtualState(index,0);
      Print("RectanglePendingEA: market entry rejected for ",rectangles[index].name,": ",result.comment);
   }
}

void ProcessVirtualEntries()
{
   if(!initialized) return;
   for(int i=0; i<ArraySize(rectangles); i++)
      if(IsRectangle(rectangles[i].name)) ProcessVirtualPlan(i);
}

void VirtualPartialMarker(const int index,string &keep[])
{
   VirtualPlan plan;
   if(!ReadVirtualPlan(index,plan) || plan.state!=1) return;
   double risk=MathAbs(plan.entry-plan.sl);
   if(PartialLevelRR>=plan.reward_rr || risk<=0) return;
   double level=PartialMarkerLevel(plan.buy,plan.entry,risk);
   double lots=PartialCloseVolume(plan.lots,plan.lots,PartialPercentage,
                                 SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),
                                 SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),
                                 SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP));
   double money=0;
   if(!MarkerProfit(plan.buy,lots,plan.entry,level,money)) return;
   DrawPartialMarker("V_"+StringSubstr(RectangleTradeTag(index),4),0,level,lots,money,keep);
}

void VirtualLevel(const string name,const double price,const color line_color,const string caption,string &keep[])
{
   if(ObjectFind(0,name)<0 && !ObjectCreate(0,name,OBJ_HLINE,0,0,price)) return;
   ObjectSetDouble(0,name,OBJPROP_PRICE,price);
   ObjectSetInteger(0,name,OBJPROP_COLOR,line_color);
   ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_DASHDOT);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_BACK,true);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,caption+" "+DoubleToString(price,_Digits));
   KeepMarker(keep,name);
}

void SyncVirtualLevels()
{
   string level_prefix=PREFIX+"Waiting_";
   string keep[];
   for(int i=0; i<ArraySize(rectangles); i++)
   {
      VirtualPlan plan;
      if(!ReadVirtualPlan(i,plan) || plan.state!=1) continue;
      string name=level_prefix+StringSubstr(RectangleTradeTag(i),4);
      VirtualLevel(name+"_Entry",plan.entry,plan.buy ? clrSeaGreen : clrIndianRed,"Waiting entry",keep);
      VirtualLevel(name+"_SL",plan.sl,clrTomato,"Waiting SL",keep);
      VirtualLevel(name+"_TP",plan.tp,clrLimeGreen,"Waiting TP",keep);
   }
   for(int i=ObjectsTotal(0,0,-1)-1; i>=0; i--)
   {
      string name=ObjectName(0,i,0,-1);
      if(StringFind(name,level_prefix)!=0) continue;
      bool live=false;
      for(int j=0; j<ArraySize(keep); j++) if(keep[j]==name) { live=true; break; }
      if(!live) ObjectDelete(0,name);
   }
}
