//+------------------------------------------------------------------+
//|                                                        State.mqh |
//|   XAU_AVG_PRO v1.0.0 - explicit, deterministic state machine    |
//|                                                                  |
//|  The state is DERIVED every cycle from three inputs only:       |
//|    1. the persisted operator flags (emergency, pause)           |
//|    2. the live risk conditions (hard limits, execution errors)  |
//|    3. the real positions on the account                          |
//|  Nothing sets the state directly except the flags above, so the |
//|  state can never drift away from reality after a restart.       |
//|                                                                  |
//|  Precedence (highest first) - docs/03-state-machine.md:         |
//|    EMERGENCY_STOP > ERROR > CLOSING > RISK_BLOCKED > PAUSED     |
//|    > IN_CYCLE / WAITING_AVERAGING > WAITING_ENTRY > IDLE        |
//+------------------------------------------------------------------+
#ifndef XAU_AVG_PRO_STATE_MQH
#define XAU_AVG_PRO_STATE_MQH

#include "Types.mqh"
#include "Logger.mqh"

class CStateMachine
  {
private:
   CConfig *m_cfg;
   CLogger *m_log;

   ENUM_XAU_STATE m_state;
   ENUM_XAU_STATE m_prev;
   string   m_reason;
   datetime m_since;
   int      m_transitions;
   bool     m_error_flag;
   string   m_error_text;
   bool     m_closing;
   bool     m_risk_blocked;
   bool     m_selftest_halt;
   datetime m_risk_until;
   ENUM_XAU_BLOCK m_risk_code;
   string   m_risk_reason;
   int      m_illegal_attempts;

   bool IsAllowed(ENUM_XAU_STATE s, const int intent)
     {
      switch(intent)
        {
         case XAU_INT_CLOSE:
            return(true);                    // closing is always allowed
         case XAU_INT_ENTRY:
            return(s == XAU_ST_WAITING_ENTRY || s == XAU_ST_IDLE);
         case XAU_INT_AVERAGING:
            return(s == XAU_ST_IN_CYCLE || s == XAU_ST_WAITING_AVERAGING);
        }
      return(false);
     }

public:
                     CStateMachine(void) : m_cfg(NULL), m_log(NULL), m_state(XAU_ST_IDLE), m_prev(XAU_ST_IDLE),
                                           m_reason("initial"), m_since(0), m_transitions(0), m_error_flag(false),
                                           m_error_text(""), m_closing(false), m_risk_blocked(false),
                                           m_selftest_halt(false), m_risk_until(0), m_risk_code(XAU_BLK_NONE),
                                           m_risk_reason(""), m_illegal_attempts(0)
     {
     }

   void Init(CConfig *cfg, CLogger *log)
     {
      m_cfg   = cfg;
      m_log   = log;
      m_state = XAU_ST_IDLE;
      m_prev  = XAU_ST_IDLE;
      m_since = XauNow();
     }

   string StateName(const ENUM_XAU_STATE s) const
     {
      switch(s)
        {
         case XAU_ST_IDLE:              return("IDLE");
         case XAU_ST_WAITING_ENTRY:     return("WAITING_ENTRY");
         case XAU_ST_IN_CYCLE:          return("IN_CYCLE");
         case XAU_ST_WAITING_AVERAGING: return("WAITING_AVERAGING");
         case XAU_ST_RISK_BLOCKED:      return("RISK_BLOCKED");
         case XAU_ST_PAUSED:            return("PAUSED");
         case XAU_ST_EMERGENCY_STOP:    return("EMERGENCY_STOP");
         case XAU_ST_CLOSING:           return("CLOSING");
         case XAU_ST_ERROR:             return("ERROR");
         case XAU_ST_SELFTEST:         return("SELFTEST_DONE");
        }
      return("UNKNOWN");
     }

   string BlockName(const ENUM_XAU_BLOCK c)
     {
      switch(c)
        {
         case XAU_BLK_NONE:               return("NONE");
         case XAU_BLK_EMERGENCY:          return("EMERGENCY");
         case XAU_BLK_PAUSED:             return("PAUSED");
         case XAU_BLK_NEWCYCLES_OFF:      return("NEW_CYCLES_DISABLED");
         case XAU_BLK_EA_DISABLED:        return("EA_DISABLED");
         case XAU_BLK_STATE_ERROR:        return("STATE_ERROR");
         case XAU_BLK_BASKET_OPEN:          return("BASKET_ALREADY_OPEN");
         case XAU_BLK_ACCOUNT_DD:         return("ACCOUNT_DD");
         case XAU_BLK_CYCLE_DD:           return("CYCLE_DD");
         case XAU_BLK_DAILY_LOSS:         return("DAILY_LOSS");
         case XAU_BLK_FLOATING_LOSS:      return("FLOATING_LOSS");
         case XAU_BLK_MARGIN:             return("MARGIN");
         case XAU_BLK_MAX_LAYER:          return("MAX_LAYER");
         case XAU_BLK_MAX_LOT_ORDER:      return("MAX_LOT_PER_ORDER");
         case XAU_BLK_MAX_TOTAL_LOT:      return("MAX_TOTAL_LOT");
         case XAU_BLK_SPREAD:             return("SPREAD");
         case XAU_BLK_VOLATILITY:         return("VOLATILITY");
         case XAU_BLK_GAP:                return("GAP");
         case XAU_BLK_SESSION:            return("SESSION");
         case XAU_BLK_WEEKEND:            return("WEEKEND");
         case XAU_BLK_OPEN_PROTECT:       return("OPEN_MARKET_PROTECTION");
         case XAU_BLK_NEWS:               return("NEWS");
         case XAU_BLK_DAILY_ENTRIES:      return("DAILY_ENTRY_LIMIT");
         case XAU_BLK_COOLDOWN:           return("COOLDOWN");
         case XAU_BLK_DIRECTION:          return("DIRECTION");
         case XAU_BLK_SPEC_INVALID:       return("SYMBOL_SPEC_INVALID");
         case XAU_BLK_NO_SIGNAL:          return("NO_SIGNAL");
         case XAU_BLK_LEVEL_NOT_REACHED:  return("LEVEL_NOT_REACHED");
         case XAU_BLK_ONE_PER_BAR:        return("ONE_LAYER_PER_BAR");
         case XAU_BLK_TOO_SOON:           return("MIN_SECONDS_BETWEEN_AVERAGING");
         case XAU_BLK_DUPLICATE_LEVEL:    return("DUPLICATE_LEVEL");
         case XAU_BLK_DISTANCE_TOO_SMALL: return("DISTANCE_BELOW_SAFE_MINIMUM");
         case XAU_BLK_NETTING_UNCERTAIN:  return("NETTING_STATE_UNCERTAIN");
         case XAU_BLK_EXEC_FAILED:        return("EXECUTION_FAILED");
         case XAU_BLK_NOT_CONNECTED:      return("NOT_CONNECTED");
        }
      return("CODE_" + IntegerToString((int)c));
     }

   //--- condition setters (only these mutate the machine) -----------
   void SetClosing(const bool closing) { m_closing = closing; }
   void SetError(const string text)
     {
      if(!m_error_flag)
        {
         m_error_flag = true;
         m_log.Error(XAU_T_STATE, "state ERROR: " + text + " | trading blocked until cleared");
        }
      m_error_text = text;
     }
   void ClearError(void)
     {
      if(m_error_flag)
         m_log.Info(XAU_T_STATE, "state ERROR cleared");
      m_error_flag = false;
      m_error_text = "";
     }
   void SetRiskBlock(const ENUM_XAU_BLOCK code, const string reason, const datetime until)
     {
      if(!m_risk_blocked || m_risk_code != code)
         m_log.Info(XAU_T_RISK, StringFormat("risk block set: %s | %s%s", BlockName(code), reason,
                                             (until > 0 ? " | until " + TimeToString(until) : "")));
      m_risk_blocked = true;
      m_risk_code    = code;
      m_risk_reason  = reason;
      m_risk_until   = until;
     }
   void ClearRiskBlock(const string why)
     {
      if(!m_risk_blocked)
         return;
      m_log.Info(XAU_T_RISK, StringFormat("risk block released (%s, was %s)", why, BlockName(m_risk_code)));
      m_risk_blocked = false;
      m_risk_code    = XAU_BLK_NONE;
      m_risk_reason  = "";
      m_risk_until   = 0;
     }
   void SetSelfTestHalt(const bool halt) { m_selftest_halt = halt; }
   bool SelfTestHalt(void) const { return(m_selftest_halt); }
   void SetEmergency(const bool on, const string why)
     {
      if(m_cfg == NULL)
         return;
      if(on && !m_cfg.emergency_stop)
         m_log.Error(XAU_T_STATE, "EMERGENCY STOP engaged: " + why);
      if(!on && m_cfg.emergency_stop)
         m_log.Info(XAU_T_STATE, "EMERGENCY STOP cleared: " + why);
      m_cfg.emergency_stop = on;
     }
   void SetPaused(const bool on, const string why)
     {
      if(m_cfg == NULL)
         return;
      if(m_cfg.user_paused != on)
         m_log.Info(XAU_T_STATE, StringFormat("PAUSED=%s (%s)", (on ? "true" : "false"), why));
      m_cfg.user_paused = on;
     }

   /// Recompute the state from the conditions. Called once per pipeline
   /// pass, before any trading decision is taken.
   /// @param basket_active  EA holds an open basket
   /// @param level_reached  the next averaging level is hit right now
   ENUM_XAU_STATE Derive(const bool basket_active, const bool level_reached)
     {
      ENUM_XAU_STATE s;
      if(m_cfg.emergency_stop)
         s = XAU_ST_EMERGENCY_STOP;
      else
         if(m_error_flag)
            s = XAU_ST_ERROR;
         else
            if(m_closing)
               s = XAU_ST_CLOSING;
            else
               if(m_risk_blocked)
                  s = XAU_ST_RISK_BLOCKED;
               else
                  if(m_cfg.user_paused)
                     s = XAU_ST_PAUSED;
                  else
                     if(m_selftest_halt)
                        s = XAU_ST_SELFTEST;
                     else
                        if(basket_active)
                           s = (level_reached ? XAU_ST_IN_CYCLE : XAU_ST_WAITING_AVERAGING);
                        else
                           s = (m_cfg.AllowNewCycles && m_cfg.EnableEMAEntry ? XAU_ST_WAITING_ENTRY : XAU_ST_IDLE);
      if(s != m_state)
        {
         m_prev       = m_state;
         m_transitions++;
         m_since      = XauNow();
         string why   = DescribeCondition();
         m_reason     = why;
         m_state      = s;
         m_log.Info(XAU_T_STATE, StringFormat("%s -> %s | %s", StateName(m_prev), StateName(m_state), why));
        }
      return(m_state);
     }

   /// Is the intent allowed in the current state? The risk manager still
   /// has the final word; this is the first gate.
   bool Allows(const ENUM_XAU_INTENT intent)
     {
      if(IsAllowed(m_state, intent))
         return(true);
      if(intent != XAU_INT_CLOSE)
         m_illegal_attempts++;
      return(false);
     }

   bool Emergency(void)      const { return(m_cfg != NULL && m_cfg.emergency_stop); }
   bool Paused(void)         const { return(m_cfg != NULL && m_cfg.user_paused); }
   bool ErrorFlag(void)      const { return(m_error_flag); }
   string ErrorText(void)    const { return(m_error_text); }
   bool   RiskBlocked(void)  const { return(m_risk_blocked); }
   ENUM_XAU_BLOCK RiskCode(void) const { return(m_risk_code); }
   string RiskReason(void)   const { return(m_risk_reason); }
   datetime RiskUntil(void)  const { return(m_risk_until); }
   ENUM_XAU_STATE State(void) const { return(m_state); }
   int  Transitions(void)     const { return(m_transitions); }
   int  IllegalAttempts(void) const { return(m_illegal_attempts); }
   datetime Since(void)      const { return(m_since); }
   string StateReason(void)  const { return(m_reason); }

   string DescribeCondition(void)
     {
      if(m_cfg != NULL && m_cfg.emergency_stop)
         return("operator/hard-stop emergency");
      if(m_error_flag)
         return("error: " + m_error_text);
      if(m_closing)
         return("basket close in progress");
      if(m_risk_blocked)
         return("risk: " + BlockName(m_risk_code) + " - " + m_risk_reason);
      if(m_cfg != NULL && m_cfg.user_paused)
         return("operator pause");
      if(m_selftest_halt)
         return("self test halt requested");
      return("normal");
     }

   string Describe(void) const
     {
      return(StringFormat("%s since %s (transitions=%d, illegal=%d)",
                          StateName(m_state), TimeToString(m_since), m_transitions, m_illegal_attempts));
     }
  };

#endif // XAU_AVG_PRO_STATE_MQH
//+------------------------------------------------------------------+
