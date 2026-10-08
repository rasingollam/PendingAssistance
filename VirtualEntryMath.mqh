// Pure entry/trigger calculations shared by execution and offline regression checks.
double SelectedEntryPrice(const bool upper,const double bottom,const double top)
{
   return upper ? top : bottom;
}

double VirtualStopPrice(const bool buy,const double entry,const double height)
{
   return buy ? entry-height : entry+height;
}

double VirtualTargetPrice(const bool buy,const double entry,const double risk,const double reward_rr)
{
   return buy ? entry+risk*reward_rr : entry-risk*reward_rr;
}

bool VirtualEntryReached(const bool rising,const double current,const double entry)
{
   return rising ? current>=entry : current<=entry;
}

double LiveEntrySpread(const double ask,const double bid)
{
   return MathMax(0.0,ask-bid);
}

bool VirtualEntryAllowed(const double current,const double entry,const double spread,const double tolerance)
{
   return MathAbs(current-entry)<=spread+tolerance;
}
