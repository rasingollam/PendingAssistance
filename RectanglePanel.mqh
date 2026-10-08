// Small, chart-native panel beside the rectangle. There is no rectangle-delete button.
string ButtonName(const int id,const int action)
{
   return PREFIX+IntegerToString(id)+"_"+IntegerToString(action);
}

string PanelName(const int id,const string part)
{
   return PREFIX+"Panel_"+IntegerToString(id)+"_"+part;
}

void RemoveButtons(const int id)
{
   for(int action=0; action<5; action++) ObjectDelete(0,ButtonName(id,action));
   ObjectDelete(0,PanelName(id,"Background"));
   for(int i=0; i<5; i++) ObjectDelete(0,PanelName(id,"Text"+IntegerToString(i)));
}

void PanelText(const int id,const int row,const int x,const int y,const string text,const color text_color)
{
   string name=PanelName(id,"Text"+IntegerToString(row));
   if(ObjectFind(0,name)<0 && !ObjectCreate(0,name,OBJ_LABEL,0,0,0)) return;
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_COLOR,text_color);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,8);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,1001);
   ObjectSetString(0,name,OBJPROP_FONT,"Segoe UI");
   ObjectSetString(0,name,OBJPROP_TEXT,text);
}

void PanelButton(const int id,const int action,const int x,const int y,const int width,
                 const string text,const color background,const string tooltip)
{
   string name=ButtonName(id,action);
   if(ObjectFind(0,name)<0 && !ObjectCreate(0,name,OBJ_BUTTON,0,0,0)) return;
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,width);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,22);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,background);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,C'66,70,79');
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,8);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,1002);
   ObjectSetString(0,name,OBJPROP_FONT,"Segoe UI");
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,tooltip);
}

void PositionButtons(const int index)
{
   string name=rectangles[index].name;
   VirtualPlan plan;
   bool cached=ReadVirtualPlan(index,plan);
   if(!IsRectangle(name) || (!cached && (RectangleHasTrade(index) ||
      !ObjectGetInteger(0,name,OBJPROP_SELECTED))))
   {
      RemoveButtons(rectangles[index].id);
      return;
   }
   int x1,y1,x2,y2;
   if(!ChartTimePriceToXY(0,0,(datetime)ObjectGetInteger(0,name,OBJPROP_TIME,0),
                        ObjectGetDouble(0,name,OBJPROP_PRICE,0),x1,y1) ||
      !ChartTimePriceToXY(0,0,(datetime)ObjectGetInteger(0,name,OBJPROP_TIME,1),
                        ObjectGetDouble(0,name,OBJPROP_PRICE,1),x2,y2))
   { RemoveButtons(rectangles[index].id); return; }
   int chart_width=(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
   int chart_height=(int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS,0);
   if(MathMax(x1,x2)<0 || MathMin(x1,x2)>chart_width ||
      MathMax(y1,y2)<0 || MathMin(y1,y2)>chart_height)
   { RemoveButtons(rectangles[index].id); return; }
   int width=cached ? 190 : 164;
   int height=cached ? 118 : 58;
   if(chart_width<width+10 || chart_height<height+10) { RemoveButtons(rectangles[index].id); return; }
   int x=(int)MathMax(5,MathMin(MathMax(x1,x2)+8,chart_width-width-5));
   int y=(int)MathMax(5,MathMin((MathMin(y1,y2)+MathMax(y1,y2)-height)/2,chart_height-height-5));
   int id=rectangles[index].id;
   string background=PanelName(id,"Background");
   if(ObjectFind(0,background)<0 && !ObjectCreate(0,background,OBJ_RECTANGLE_LABEL,0,0,0)) return;
   ObjectSetInteger(0,background,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,background,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,background,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,background,OBJPROP_XSIZE,width);
   ObjectSetInteger(0,background,OBJPROP_YSIZE,height);
   ObjectSetInteger(0,background,OBJPROP_BGCOLOR,C'24,27,32');
   ObjectSetInteger(0,background,OBJPROP_COLOR,C'66,70,79');
   ObjectSetInteger(0,background,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,background,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,background,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,background,OBJPROP_BACK,false);
   ObjectSetInteger(0,background,OBJPROP_ZORDER,1000);
   if(cached)
   {
      for(int action=0; action<4; action++) ObjectDelete(0,ButtonName(id,action));
      string status=plan.state==1 ? "WAITING" : "CHECK TRADE / HISTORY";
      PanelText(id,0,x+8,y+6,(plan.buy ? "BUY " : "SELL ")+status,
                plan.state==1 ? (plan.buy ? clrMediumSeaGreen : clrSalmon) : clrOrange);
      PanelText(id,1,x+8,y+24,(plan.upper ? "Upper " : "Lower ")+DoubleToString(plan.entry,_Digits),clrWhite);
      PanelText(id,2,x+8,y+38,"SL  "+DoubleToString(plan.sl,_Digits),clrSilver);
      PanelText(id,3,x+8,y+52,"TP  "+DoubleToString(plan.tp,_Digits),clrSilver);
      PanelText(id,4,x+8,y+66,DoubleToString(plan.lots,2)+" lots  "+
                DoubleToString(plan.estimated_loss,2)+" "+AccountInfoString(ACCOUNT_CURRENCY)+" risk",clrSilver);
      if(plan.state==1)
         PanelButton(id,4,x+6,y+90,width-12,"Cancel",C'69,73,82',"Cancel the waiting trade; keep the rectangle");
      else ObjectDelete(0,ButtonName(id,4));
      return;
   }
   ObjectDelete(0,ButtonName(id,4));
   for(int i=0; i<5; i++) ObjectDelete(0,PanelName(id,"Text"+IntegerToString(i)));
   color selected=C'46,117,180',neutral=C'48,52,60';
   PanelButton(id,0,x+6,y+6,74,"Upper",rectangles[index].upper ? selected : neutral,"Use the rectangle's upper price as entry");
   PanelButton(id,1,x+84,y+6,74,"Lower",rectangles[index].upper ? neutral : selected,"Use the rectangle's lower price as entry");
   PanelButton(id,2,x+6,y+30,74,"Buy",C'35,125,82',"Arm a BUY at the selected edge");
   PanelButton(id,3,x+84,y+30,74,"Sell",C'162,58,62',"Arm a SELL at the selected edge");
}
