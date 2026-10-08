// One partial-close event per position. Terminal globals survive ordinary EA/terminal restarts.
string partial_scope;
string partial_lock;

void PreparePartialManagement()
{
   ulong account_hash=14695981039346656037;
   string account=AccountInfoString(ACCOUNT_SERVER)+":"+IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   for(int i=0; i<StringLen(account); i++)
      account_hash=(account_hash^(ulong)StringGetCharacter(account,i))*1099511628211;
   // Keep all global names below 63 characters, and separate tester state from live state.
   partial_scope=(MQLInfoInteger(MQL_TESTER) ? "RPT." : "RPE.")+StringFormat("%I64X",account_hash)+".";
   partial_lock=partial_scope+"Lock";
   // Existing temporary globals are not overwritten. Lock covers all instances in this terminal.
   GlobalVariableTemp(partial_lock);
}

bool PartialTradingAllowed()
{
   return TerminalInfoInteger(TERMINAL_CONNECTED) &&
          TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) &&
          MQLInfoInteger(MQL_TRADE_ALLOWED) &&
          AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) &&
          AccountInfoInteger(ACCOUNT_TRADE_EXPERT);
}

void PartialLog(const string key,const string message,const int seconds=60)
{
   datetime now=TimeLocal();
   if(GlobalVariableCheck(key+".Log") && now<(datetime)GlobalVariableGet(key+".Log")) return;
   Print("RectanglePendingEA partial: ",message);
   GlobalVariableSet(key+".Log",(double)(now+seconds));
}

double PartialCloseVolume(const double original,const double current,const double percentage,
                          const double minimum,const double maximum,const double step)
{
   if(minimum<=0 || step<=0 || maximum<minimum || current<2*minimum-1e-10) return 0;
   // Round down, and always leave at least the minimum tradable volume open.
   double cap=MathMin(original*percentage/100.0,MathMin(maximum,current-minimum));
   double volume=NormalizeDouble(MathFloor((cap+step*1e-8)/step)*step,8);
   if(volume<minimum-1e-10 || current-volume<minimum-1e-10 || volume>=current) return 0;
   return volume;
}

// Read the original SL from entry history, and reject mixed-ownership netting positions.
bool PartialHistory(const ulong identifier,double &initial_sl,
                    bool &already_closed,long &generation)
{
   if(!HistorySelectByPosition(identifier)) return false;
   bool netting=(ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;
   initial_sl=0;
   already_closed=false;
   generation=0;
   int count=HistoryDealsTotal();
   // A netting reversal reuses the position identifier but starts a new direction/lifetime.
   for(int i=0; i<count; i++)
   {
      ulong deal=HistoryDealGetTicket(i);
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY)==DEAL_ENTRY_INOUT)
         generation=HistoryDealGetInteger(deal,DEAL_TIME_MSC);
   }
   for(int i=0; i<count; i++)
   {
      ulong deal=HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(deal,DEAL_TIME_MSC)<generation) continue;
      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY);
      ulong magic=(ulong)HistoryDealGetInteger(deal,DEAL_MAGIC);
      if(entry==DEAL_ENTRY_IN || entry==DEAL_ENTRY_INOUT)
      {
         if(netting && magic!=MAGIC) return false;
         double sl=HistoryDealGetDouble(deal,DEAL_SL);
         if(initial_sl==0 && sl>0) initial_sl=sl;
      }
      if((entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY) && magic==MAGIC &&
         StringFind(HistoryDealGetString(deal,DEAL_COMMENT),"RectPartial")==0)
         already_closed=true;
   }
   return true;
}

bool PartialFilling(ENUM_ORDER_TYPE_FILLING &filling)
{
   long flags=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   ENUM_SYMBOL_TRADE_EXECUTION execution=(ENUM_SYMBOL_TRADE_EXECUTION)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_EXEMODE);
   if((flags&SYMBOL_FILLING_FOK)!=0) filling=ORDER_FILLING_FOK;
   else if((flags&SYMBOL_FILLING_IOC)!=0) filling=ORDER_FILLING_IOC;
   else if(execution!=SYMBOL_TRADE_EXECUTION_MARKET) filling=ORDER_FILLING_RETURN;
   else return false;
   return true;
}

bool BreakEvenAlreadyProtected(const bool buy,const double sl,const double entry,const double tolerance)
{
   if(sl<=0) return false;
   return buy ? sl>=entry-tolerance : sl<=entry+tolerance;
}

void MovePartialToBreakEven(const ulong ticket,const string key)
{
   if(!IsBEAfterPartial || !PartialTradingAllowed()) return;
   if(GlobalVariableCheck(key+".BE") && GlobalVariableGet(key+".BE")==1) return;
   if(!PositionSelectByTicket(ticket) || PositionGetString(POSITION_SYMBOL)!=_Symbol ||
      (ulong)PositionGetInteger(POSITION_MAGIC)!=MAGIC) return;
   bool buy=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY;
   double entry=PositionGetDouble(POSITION_PRICE_OPEN);
   double sl=PositionGetDouble(POSITION_SL);
   double tp=PositionGetDouble(POSITION_TP);
   double tick_size=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tick_size<=0) return;
   double target=NormalizeDouble(MathRound(entry/tick_size)*tick_size,_Digits);
   if(BreakEvenAlreadyProtected(buy,sl,target,tick_size*1e-6))
   {
      // Never loosen a stop already at break-even or further into profit.
      GlobalVariableSet(key+".BE",1);
      GlobalVariablesFlush();
      return;
   }
   if(GlobalVariableCheck(key+".BT") && TimeLocal()<(datetime)GlobalVariableGet(key+".BT")) return;
   GlobalVariableSet(key+".BT",(double)(TimeLocal()+10));
   MqlTick quote={};
   if(!SymbolInfoTick(_Symbol,quote) || quote.bid<=0 || quote.ask<=0) return;
   double distance=buy ? quote.bid-target : target-quote.ask;
   double stops=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   double freeze=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL)*_Point;
   if(distance<=0 || distance+tick_size*1e-6<stops || distance<=freeze)
   {
      PartialLog(key,"Break-even for #"+IntegerToString((long)ticket)+
                 " is too close to market; will retry when broker distance rules allow.");
      return;
   }
   MqlTradeRequest request={};
   MqlTradeCheckResult check={};
   MqlTradeResult result={};
   request.action=TRADE_ACTION_SLTP;
   request.position=ticket;
   request.symbol=_Symbol;
   request.magic=MAGIC;
   request.sl=target;
   request.tp=tp;
   if(!OrderCheck(request,check))
   {
      PartialLog(key,"Break-even check failed for #"+IntegerToString((long)ticket)+": "+check.comment);
      return;
   }
   bool sent=OrderSend(request,result);
   if(sent && (result.retcode==TRADE_RETCODE_DONE || result.retcode==TRADE_RETCODE_NO_CHANGES))
   {
      GlobalVariableSet(key+".BE",1);
      GlobalVariablesFlush();
      PrintFormat("RectanglePendingEA: position #%I64u SL moved to break-even at %.*f.",ticket,_Digits,target);
   }
   else
      PartialLog(key,"Break-even failed for #"+IntegerToString((long)ticket)+": "+result.comment+
                 " ("+IntegerToString((int)result.retcode)+"); will retry.");
}

void ManagePartialPosition(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket) || PositionGetString(POSITION_SYMBOL)!=_Symbol) return;
   if((ulong)PositionGetInteger(POSITION_MAGIC)!=MAGIC) return;
   bool buy=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY;
   ulong identifier=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
   double initial_sl=0;
   bool history_done=false;
   long generation=0;
   // History also lets the manager recover its own close marker if globals were lost.
   if(!PartialHistory(identifier,initial_sl,history_done,generation)) return;
   string key=partial_scope+IntegerToString((long)identifier)+"."+IntegerToString(generation);
   if(history_done)
   {
      if(!GlobalVariableCheck(key+".S") || GlobalVariableGet(key+".S")!=2)
      {
         GlobalVariableSet(key+".S",2);
         GlobalVariablesFlush();
      }
      MovePartialToBreakEven(ticket,key);
      return;
   }
   if(!PositionSelectByTicket(ticket)) return;
   double current_volume=PositionGetDouble(POSITION_VOLUME);
   if(GlobalVariableCheck(key+".S"))
   {
      double state=GlobalVariableGet(key+".S");
      if(state==2)
      {
         MovePartialToBreakEven(ticket,key);
         return;
      }
      if(state==1)
      {
         // An accepted, delayed or timed-out request is never resent blindly.
         if(GlobalVariableCheck(key+".Before") && current_volume<GlobalVariableGet(key+".Before")-1e-10)
         {
            GlobalVariableSet(key+".S",2);
            GlobalVariablesFlush();
            MovePartialToBreakEven(ticket,key);
         }
         return;
      }
   }
   if(!GlobalVariableCheck(key+".R"))
   {
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      if(initial_sl<=0) initial_sl=PositionGetDouble(POSITION_SL);
      double risk=buy ? entry-initial_sl : initial_sl-entry;
      if(initial_sl<=0 || risk<=0)
      {
         PartialLog(key,"Position #"+IntegerToString((long)ticket)+" has no usable initial SL; skipped.");
         return;
      }
      GlobalVariableSet(key+".E",entry);
      GlobalVariableSet(key+".V",current_volume);
      GlobalVariableSet(key+".R",risk);
      GlobalVariableSet(key+".S",0);
      GlobalVariablesFlush();
   }
   if(!PartialTradingAllowed()) return;
   if(GlobalVariableCheck(key+".Retry") && TimeLocal()<(datetime)GlobalVariableGet(key+".Retry")) return;
   MqlTick quote={};
   if(!SymbolInfoTick(_Symbol,quote) || quote.bid<=0 || quote.ask<=0) return;
   double entry=GlobalVariableGet(key+".E");
   double risk=GlobalVariableGet(key+".R");
   double tp=PositionGetDouble(POSITION_TP);
   if(tp>0 && (buy ? tp-entry : entry-tp)<=risk*PartialLevelRR)
   {
      PartialLog(key,"Position #"+IntegerToString((long)ticket)+
                 " has TP at/before the partial level; use a lower PartialLevelRR or a farther TP.");
      return;
   }
   double movement=buy ? quote.bid-entry : entry-quote.ask;
   if(movement<risk*PartialLevelRR) return;
   // An altered/scaled position is not the original trade; do not use its old R calculation.
   if(MathAbs(PositionGetDouble(POSITION_PRICE_OPEN)-entry)>_Point*0.1 ||
      current_volume>GlobalVariableGet(key+".V")+1e-10)
   {
      PartialLog(key,"Position #"+IntegerToString((long)ticket)+" was scaled/altered; automatic partial skipped.");
      return;
   }
   double volume=PartialCloseVolume(GlobalVariableGet(key+".V"),current_volume,PartialPercentage,
                                   SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),
                                   SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),
                                   SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP));
   if(volume<=0)
   {
      PartialLog(key,"Position #"+IntegerToString((long)ticket)+" is too small for a valid partial and remainder.");
      return;
   }
   MqlTradeRequest request={};
   MqlTradeCheckResult check={};
   MqlTradeResult result={};
   request.action=TRADE_ACTION_DEAL;
   request.position=ticket; // Required for hedging; opposite deal reduces the position in netting.
   request.symbol=_Symbol;
   request.magic=MAGIC;
   request.type=buy ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.volume=volume;
   request.price=buy ? quote.bid : quote.ask;
   request.deviation=20;
   request.comment="RectPartial";
   if(!PartialFilling(request.type_filling)) { PartialLog(key,"No supported closing fill policy."); return; }
   if(!OrderCheck(request,check))
   {
      PartialLog(key,"Close check failed for #"+IntegerToString((long)ticket)+": "+check.comment);
      GlobalVariableSet(key+".Retry",(double)(TimeLocal()+10));
      return;
   }
   // Refresh just before sending to avoid closing a stale/full volume or wrong position direction.
   if(!PositionSelectByTicket(ticket) ||
      (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=identifier ||
      ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)!=buy ||
      MathAbs(PositionGetDouble(POSITION_VOLUME)-current_volume)>1e-10) return;
   GlobalVariableSet(key+".Before",current_volume);
   GlobalVariableSet(key+".S",1);
   GlobalVariablesFlush();
   bool sent=OrderSend(request,result);
   if(sent && (result.retcode==TRADE_RETCODE_DONE || result.retcode==TRADE_RETCODE_DONE_PARTIAL))
   {
      GlobalVariableSet(key+".S",2);
      GlobalVariablesFlush();
      PrintFormat("RectanglePendingEA partial: position #%I64u closed %.8f lots at %.2fR; requested %.1f%% (retcode %u).",
                  ticket,result.volume,movement/risk,PartialPercentage,result.retcode);
      MovePartialToBreakEven(ticket,key);
   }
   else if(result.retcode==TRADE_RETCODE_PLACED || result.retcode==TRADE_RETCODE_TIMEOUT ||
           result.retcode==TRADE_RETCODE_CONNECTION)
      PartialLog(key,"Close outcome pending/uncertain for #"+IntegerToString((long)ticket)+
                 "; no duplicate request will be sent. Check Trade/History.");
   else
   {
      GlobalVariableSet(key+".S",0);
      GlobalVariableSet(key+".Retry",(double)(TimeLocal()+10));
      GlobalVariablesFlush();
      PartialLog(key,"Close rejected for #"+IntegerToString((long)ticket)+": "+result.comment+
                 " ("+IntegerToString((int)result.retcode)+"). Retry after 10 seconds.",10);
   }
}

void ManagePartialProfit()
{
   if(!initialized || !IsPartialProfit || partial_lock=="") return;
   // Expiring lease also recovers if an instance was forcibly stopped during management.
   double previous=GlobalVariableGet(partial_lock);
   double now=(double)TimeLocal();
   if(previous>now || !GlobalVariableSetOnCondition(partial_lock,now+120,previous)) return;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      GlobalVariableSet(partial_lock,(double)TimeLocal()+120);
      ulong ticket=PositionGetTicket(i);
      if(ticket!=0) ManagePartialPosition(ticket);
   }
   GlobalVariableSet(partial_lock,0);
}
