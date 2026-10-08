// Link rectangles to the actual order/position lifetime instead of hiding controls forever.
string RectangleTradeTag(const int index)
{
   ulong hash=14695981039346656037;
   string identity=_Symbol+":"+rectangles[index].name;
   for(int i=0; i<StringLen(identity); i++)
      hash=(hash^(ulong)StringGetCharacter(identity,i))*1099511628211;
   return "RPE:"+StringFormat("%I64X",hash); // Fits the broker's 31-character comment limit.
}

string RectangleTradeKey(const int index)
{
   return partial_scope+RectangleTradeTag(index);
}

void MarkRectangleUncertain(const int index,const bool uncertain)
{
   GlobalVariableSet(RectangleTradeKey(index)+".U",uncertain ? 1 : 0);
   GlobalVariablesFlush();
}

void LinkRectangleOrder(const int index,const ulong order)
{
   if(order==0) return; // Keep an unconfirmed submission locked against a second click.
   string key=RectangleTradeKey(index);
   // Two 32-bit words preserve even ticket numbers larger than a double's exact integer range.
   GlobalVariableSet(key+".Hi",(double)(order>>32));
   GlobalVariableSet(key+".Lo",(double)(order&0xFFFFFFFF));
   GlobalVariableSet(key+".U",0);
   GlobalVariablesFlush();
}

ulong LinkedRectangleOrder(const int index)
{
   string key=RectangleTradeKey(index);
   if(!GlobalVariableCheck(key+".Hi") || !GlobalVariableCheck(key+".Lo")) return 0;
   return ((ulong)GlobalVariableGet(key+".Hi")<<32)|(ulong)GlobalVariableGet(key+".Lo");
}

bool RectangleOrderStillActive(const ulong order)
{
   if(OrderSelect(order)) return true;
   if(!HistoryOrderSelect(order)) return true; // History may lag the pending-to-open transition.
   ulong identifier=(ulong)HistoryOrderGetInteger(order,ORDER_POSITION_ID);
   if(identifier==0) return false; // Cancelled/expired without opening a position.
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket!=0 && PositionGetString(POSITION_SYMBOL)==_Symbol &&
         (ulong)PositionGetInteger(POSITION_IDENTIFIER)==identifier) return true;
   }
   return false;
}

// Recover older EA trades without a rectangle tag using their original entry/SL geometry.
bool LegacyRectangleMatch(const int index,const bool buy,const double entry,const double sl)
{
   double tick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tick<=0 || sl<=0) return false;
   double p1=ObjectGetDouble(0,rectangles[index].name,OBJPROP_PRICE,0);
   double p2=ObjectGetDouble(0,rectangles[index].name,OBJPROP_PRICE,1);
   double bottom=NormalizeDouble(MathRound(MathMin(p1,p2)/tick)*tick,_Digits);
   double top=NormalizeDouble(MathRound(MathMax(p1,p2)/tick)*tick,_Digits);
   double height=top-bottom;
   double stop_entry=buy ? bottom : top;
   double stop_sl=buy ? bottom-height : top+height;
   double limit_entry=buy ? top : bottom;
   double limit_sl=buy ? bottom : top;
   double tolerance=tick*0.1;
   return (MathAbs(entry-stop_entry)<=tolerance && MathAbs(sl-stop_sl)<=tolerance) ||
          (MathAbs(entry-limit_entry)<=tolerance && MathAbs(sl-limit_sl)<=tolerance);
}

bool RectangleOrderMatches(const int index,const string comment,const ENUM_ORDER_TYPE type,
                           const double entry,const double sl)
{
   if(comment==RectangleTradeTag(index)) return true;
   if(comment!="RectanglePendingEA") return false;
   bool buy=type==ORDER_TYPE_BUY || type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_BUY_LIMIT;
   return LegacyRectangleMatch(index,buy,entry,sl);
}

ulong RecoverRectangleOrder(const int index)
{
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong order=OrderGetTicket(i);
      if(order==0 || OrderGetString(ORDER_SYMBOL)!=_Symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC)!=MAGIC) continue;
      if(RectangleOrderMatches(index,OrderGetString(ORDER_COMMENT),
                               (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE),
                               OrderGetDouble(ORDER_PRICE_OPEN),OrderGetDouble(ORDER_SL))) return order;
   }
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      ulong identifier=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      if(!HistorySelectByPosition(identifier)) continue;
      for(int j=HistoryDealsTotal()-1; j>=0; j--)
      {
         ulong deal=HistoryDealGetTicket(j);
         ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY);
         if((entry!=DEAL_ENTRY_IN && entry!=DEAL_ENTRY_INOUT) ||
            (ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=MAGIC) continue;
         ulong order=(ulong)HistoryDealGetInteger(deal,DEAL_ORDER);
         if(!HistoryOrderSelect(order)) continue;
         if(RectangleOrderMatches(index,HistoryOrderGetString(order,ORDER_COMMENT),
                                  (ENUM_ORDER_TYPE)HistoryOrderGetInteger(order,ORDER_TYPE),
                                  HistoryOrderGetDouble(order,ORDER_PRICE_OPEN),
                                  HistoryOrderGetDouble(order,ORDER_SL))) return order;
      }
   }
   return 0;
}

bool RectangleHasTrade(const int index)
{
   string uncertain_key=RectangleTradeKey(index)+".U";
   if(GlobalVariableCheck(uncertain_key) && GlobalVariableGet(uncertain_key)==1)
   {
      ulong recovered=RecoverRectangleOrder(index);
      if(recovered!=0) LinkRectangleOrder(index,recovered);
      return true; // Unknown outcome stays locked even if a previous linked trade already closed.
   }
   ulong order=LinkedRectangleOrder(index);
   if(order!=0)
   {
      bool active=RectangleOrderStillActive(order);
      rectangles[index].submitted=active;
      return active;
   }
   order=RecoverRectangleOrder(index);
   if(order!=0)
   {
      LinkRectangleOrder(index,order);
      rectangles[index].submitted=true;
      return true;
   }
   return rectangles[index].submitted;
}
