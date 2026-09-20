//+------------------------------------------------------------------+
//|                                                   Telegram.mqh   |
//|  XAU_AVG_PRO v1.0.0 - Telegram monitoring + control centre      |
//|                                                                  |
//  Security model:                                                  |
//   - the bot token only ever comes from an input; it is never     |
//     written to a log, the dashboard, a CSV or another message     |
//   - only a fixed whitelist of commands is executed; anything     |
//     else is rejected. No shell, no evaluation, no dynamic calls.  |
//   - the chat id of every update is compared with TelegramChatID; |
//     updates from anybody else are dropped and counted            |
//   - destructive commands require an explicit second message      |
//     (/confirm_closeall) that expires after 90 seconds            |
//   - all argument values are range checked by the ENGINE, not here|
//     (this module only sanitises and tokenises)                    |
//                                                                  |
//  Network model:                                                   |
//   - WebRequest only (MT5 has no inbound sockets). getUpdates is  |
//     polled on a timer, which is why TelegramPollingIntervalSeconds|
//     exists; api.telegram.org must be listed in the terminal's    |
//     allowed URLs.                                                |
//   - in the Strategy Tester, and whenever WebRequest is refused,  |
//     the module disables itself and says why (fail safe).         |
//                                                                  |
//  Commands are handed to the engine through a queue: this module  |
//  never touches trading objects, so it cannot bypass risk checks. |
//+------------------------------------------------------------------+
#ifndef XAU_AVG_PRO_TELEGRAM_MQH
#define XAU_AVG_PRO_TELEGRAM_MQH

#include "Types.mqh"
#include "Logger.mqh"
#include "StateStore.mqh"

#define XAU_TG_API      "https://api.telegram.org"
#define XAU_TG_CONFIRM_SECONDS 90

class CTelegramBot
  {
private:
   CConfig     *m_cfg;
   CLogger     *m_log;
   CStateStore *m_store;

   bool      m_enabled;
   bool      m_blocked_reason_shown;
   string    m_disabled_why;
   datetime  m_next_poll;
   datetime  m_last_poll_ok;
   datetime  m_next_notify;
   long      m_offset;
   int       m_sent;
   int       m_recv;
   int       m_rejected;
   int       m_errors;
   int       m_dropped_cmd;
   string    m_last_error;
   string    m_pending_action;        // destructive command awaiting /confirm
   datetime  m_pending_until;
   datetime  m_rate[];              // outbound message timestamps

   // command queue consumed by the engine
   string    m_cmd[];
   string    m_args[];

   //--- helpers ------------------------------------------------------
   bool HaveNetwork(void) const
     {
      // WebRequest is refused by the tester and by terminals where the
      // URL is not whitelisted. Both are detected by the call itself.
      return(!(bool)MQLInfoInteger(MQL_TESTER));
     }
   bool TokenLooksValid(void)
     {
      string t = m_cfg.TelegramBotToken;
      int colon = StringFind(t, ":");
      if(colon < 6 || colon > 40)
         return(false);
      for(int i = 0; i < StringLen(t); i++)
        {
         ushort c = StringGetCharacter(t, i);
         bool ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') ||
                   (c >= 'A' && c <= 'Z') || c == '-' || c == '_' || c == ':';
         if(!ok)
            return(false);
        }
      return(true);
     }
   string MaskToken(const string text)
     {
      string s = text;
      string t = m_cfg.TelegramBotToken;
      if(StringLen(t) > 0)
        {
         string masked = StringFormat("***token(len %d)***", StringLen(t));
         StringReplace(s, t, masked);
        }
      // a URL that leaked into a response body must never be echoed
      int p = StringFind(s, "/bot");
      if(p >= 0)
         s = StringSubstr(s, 0, p) + "/bot***";
      return(s);
     }
   string UrlEncode(const string text)
     {
      string out = "";
      uchar buf[];
      int len = StringToCharArray(text, buf, 0, WHOLE_ARRAY, CP_UTF8);
      // StringToCharArray appends a zero terminator - drop it
      if(len > 0)
         len = ArraySize(buf) - 1;
      for(int i = 0; i < len; i++)
        {
         int c = (int)buf[i] & 0xFF;
         bool safe = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                     c == '-' || c == '_' || c == '.' || c == '~';
         if(safe)
            out += CharToString((uchar)c);
         else
            out += StringFormat("%%%02X", c);
        }
      return(out);
     }
   /// Chat id of an update. It must be read from the "chat" object:
   /// "from":{"id":...} appears first in the payload and is the USER id,
   /// so a naive "id" search would authorise on the wrong number.
   bool ExtractChatId(const string chunk, long &chat)
     {
      int p = StringFind(chunk, "\"chat\":");
      if(p < 0)
         return(false);
      string tail = StringSubstr(chunk, p);
      return(ExtractLong(tail, "id", chat));
     }
   /// Minimal JSON field extraction. The Bot API answer is flat enough for
   /// this; a full parser would be more code for no safety gain here.
   bool ExtractString(const string json, const string key, string &out)
     {
      string needle = "\"" + key + "\":\"";
      int p = StringFind(json, needle);
      if(p < 0)
         return(false);
      p += StringLen(needle);
      string acc = "";
      for(int i = p; i < StringLen(json); i++)
        {
         ushort c = StringGetCharacter(json, i);
         if(c == '\\')
           {
            i++;
            ushort n = (i < StringLen(json) ? StringGetCharacter(json, i) : ' ');
            if(n == 'n')
               acc += "\n";
            else
               if(n == 't')
                  acc += " ";
                else
                   if(n == 'r')
                      continue;
                    else
                       if(n == 'u')
                        {
                         // non ASCII escape: commands are ASCII, so mark it
                         acc += "?";
                         i += 4;
                        }
                      else
                         acc += ShortToString(n);
            continue;
           }
         if(c == '"')
            break;
         acc += ShortToString(c);
        }
      out = acc;
      return(true);
     }
   bool ExtractLong(const string json, const string key, long &out)
     {
      string needle = "\"" + key + "\":";
      int p = StringFind(json, needle);
      if(p < 0)
         return(false);
      p += StringLen(needle);
      string digits = "";
      if(p < StringLen(json) && StringGetCharacter(json, p) == '-')
        {
         digits = "-";
         p++;
        }
      for(int i = p; i < StringLen(json); i++)
        {
         ushort c = StringGetCharacter(json, i);
         if(c < '0' || c > '9')
            break;
         digits += ShortToString(c);
        }
      if(StringLen(digits) == 0 || digits == "-")
         return(false);
      out = StringToInteger(digits);
      return(true);
     }
   bool Api(const string method, const string query, string &response)
     {
      response = "";
      string url = XAU_TG_API + "/bot" + m_cfg.TelegramBotToken + "/" + method;
      if(StringLen(query) > 0)
         url += "?" + query;
      // WebRequest(method, url, headers, timeout, uchar &send[], uchar &recv[], string &result_headers)
      // - the body/response buffers are 'uchar' arrays because that is the element type
      // the documented overloads declare, and the request-header argument is a string, not
      // NULL: a wrong element type or a NULL header argument is "no one of the overloads
      // can be applied to the function call", which is exactly how this call failed.
      uchar send[];
      uchar recv[];
      string headers = "";
      string result_headers = "";
      int code = WebRequest("GET", url, headers, m_cfg.TelegramRequestTimeoutMs, send, recv, result_headers);
      if(code == -1)
        {
         m_errors++;
         m_last_error = StringFormat("WebRequest failed (err=%d) for %s/%s", GetLastError(), XAU_TG_API, method);
         return(false);
        }
      if(code != 200)
        {
         m_errors++;
         string body = CharArrayToString(recv, 0, WHOLE_ARRAY, CP_UTF8);
         m_last_error = StringFormat("HTTP %d from %s: %s", code, method, StringSubstr(body, 0, 160));
         return(false);
        }
      // The conversion cannot fail into a bool - an empty body is the failure it signals.
      string body = CharArrayToString(recv, 0, WHOLE_ARRAY, CP_UTF8);
      if(StringLen(body) == 0)
        {
         m_errors++;
         m_last_error = "empty response body from the Bot API";
         return(false);
        }
      response = body;
      return(true);
     }
   bool RateAllows(void)
     {
      int limit = (int)XauClampI(m_cfg.TelegramMaxMessagesPerMinute, 1, 60);
      datetime now = XauNow();
      int keep = 0;
      int n = ArraySize(m_rate);
      for(int i = 0; i < n; i++)
         if((int)(now - m_rate[i]) < 60)
           {
            m_rate[keep] = m_rate[i];
            keep++;
           }
      ArrayResize(m_rate, keep);
      if(keep >= limit)
        {
         m_dropped_cmd++;
         return(false);
        }
      ArrayResize(m_rate, keep + 1);
      m_rate[keep] = now;
      return(true);
     }
   void QueueCommand(const string name, const string args)
     {
      int n = ArraySize(m_cmd);
      if(n >= 16)                       // hard backlog limit
        {
         m_rejected++;
         return;
        }
      ArrayResize(m_cmd, n + 1);
      ArrayResize(m_args, n + 1);
      m_cmd[n]  = name;
      m_args[n] = args;
     }
   bool IsWhitelisted(const string name)
     {
      string allowed[] = {"status","start","stop","pause","resume","closeall","closebuy","closesell",
                          "confirm_closeall","confirm_closebuy","confirm_closesell","cancel",
                          "setlot","setmultiplier","setdistance","settp","setcutloss","setdirection",
                          "setmaxlayer","setmaxlot","stats","report","help","emergency","emergency_clear",
                          "resetparams","version","ping"};
      for(int i = 0; i < ArraySize(allowed); i++)
         if(allowed[i] == name)
            return(true);
      return(false);
     }

public:
                     CTelegramBot(void) : m_cfg(NULL), m_log(NULL), m_store(NULL), m_enabled(false),
                                          m_blocked_reason_shown(false), m_disabled_why(""), m_next_poll(0),
                                          m_last_poll_ok(0), m_next_notify(0), m_offset(0), m_sent(0), m_recv(0),
                                          m_rejected(0), m_errors(0), m_dropped_cmd(0), m_last_error(""),
                                          m_pending_action(""), m_pending_until(0)
     {
     }

   /// Decide once, at OnInit, whether Telegram can run at all.
   void Init(CConfig *cfg, CLogger *log, CStateStore *store)
     {
      m_cfg   = cfg;
      m_log   = log;
      m_store = store;
      m_enabled = false;
      if(!m_cfg.EnableTelegram)
        {
         m_disabled_why = "disabled by input EnableTelegram=false";
         return;
        }
      if(!HaveNetwork())
        {
         m_disabled_why = "Strategy Tester: WebRequest is not available, Telegram auto-disabled";
         m_log.Warn(XAU_T_TG, m_disabled_why);
         return;
        }
      if(StringLen(m_cfg.TelegramBotToken) < 8 || StringLen(m_cfg.TelegramChatID) < 1)
        {
         m_disabled_why = "TelegramBotToken / TelegramChatID not configured";
         m_log.Error(XAU_T_TG, m_disabled_why + " - Telegram stays off (no credentials are ever guessed)");
         return;
        }
      if(!TokenLooksValid())
        {
         m_disabled_why = "TelegramBotToken does not look like <digits>:<token>";
         m_log.Error(XAU_T_TG, m_disabled_why + " - Telegram stays off");
         return;
        }
      m_offset = 0;
      if(m_store != NULL && m_store.Enabled())
         m_offset = m_store.GetIntOr("tg_offset", 0);
      m_enabled = true;
      m_log.Info(XAU_T_TG, StringFormat("enabled for chat %s, polling every %d s. Terminal must allow %s in Tools>Options>Expert Advisors",
                                        m_cfg.TelegramChatID, m_cfg.TelegramPollingIntervalSeconds, XAU_TG_API));
      // one connectivity probe: a blocked URL must fail loudly at start,
      // not silently, and it must never disable trading
      string probe = "";
      if(!Api("getMe", "", probe))
        {
         m_enabled = false;
         m_disabled_why = "getMe failed: " + m_last_error +
                          " | add " + XAU_TG_API + " to the allowed URL list (Tools . Options . Expert Advisors)";
         m_log.Error(XAU_T_TG, m_disabled_why);
         return;
        }
      string name = "";
      if(ExtractString(probe, "username", name))
         m_log.Info(XAU_T_TG, "connected as @" + name);
      Notify(XAU_EA_NAME + " v" + XAU_EA_VERSION + " STARTED on " + m_cfg.EANameLabel +
             "\nEA id/magic " + IntegerToString(m_cfg.MagicNumber));
     }

   void Deinit(const string why)
     {
      if(m_enabled)
         Notify(XAU_EA_NAME + " stopped (" + why + ")");
      m_enabled = false;
     }

   bool     Enabled(void)      const { return(m_enabled); }
   string   DisabledWhy(void)  const { return(m_disabled_why); }
   string   LastError(void)    const { return(m_last_error); }
   int      SentCount(void)    const { return(m_sent); }
   int      RecvCount(void)    const { return(m_recv); }
   int      RejectedCount(void) const { return(m_rejected); }
   int      ErrorCount(void)   const { return(m_errors); }
   int      DroppedCount(void) const { return(m_dropped_cmd); }
   datetime LastPollOk(void)   const { return(m_last_poll_ok); }
   bool     HasPendingConfirm(void) const { return(StringLen(m_pending_action) > 0 && XauNow() < m_pending_until); }
   string   PendingAction(void) const { return(m_pending_action); }

   string Describe(void) const
     {
      if(!m_enabled)
         return("off: " + m_disabled_why);
      return(StringFormat("on | sent %d, recv %d, rejected %d, dropped %d, last poll %s",
                          m_sent, m_recv, m_rejected, m_dropped_cmd,
                          (m_last_poll_ok > 0 ? TimeToString(m_last_poll_ok, TIME_SECONDS) : "never")));
     }

   /// Outbound notification. Never called from inside the order path in a
   /// way that could delay execution: every call is rate limited and short.
   bool Notify(const string text)
     {
      if(!m_enabled || !m_cfg.TelegramNotifyOnEvents)
         return(false);
      if(!RateAllows())
         return(false);
      string body = text;
      if(StringLen(body) > 3500)
         body = StringSubstr(body, 0, 3400) + "\n...truncated";
      string query = "chat_id=" + m_cfg.TelegramChatID + "&text=" + UrlEncode(body) +
                     "&disable_web_page_preview=true";
      string resp = "";
      if(!Api("sendMessage", query, resp))
        {
         m_log.Throttled(1, XAU_T_TG, "send", "sendMessage failed: " + MaskToken(m_last_error), 120);
         return(false);
        }
      m_sent++;
      return(true);
     }
   /// Notification that bypasses TelegramNotifyOnEvents (operator asked for it).
   bool Reply(const string text)
     {
      if(!m_enabled)
         return(false);
      bool save = m_cfg.TelegramNotifyOnEvents;
      m_cfg.TelegramNotifyOnEvents = true;
      bool ok = Notify(text);
      m_cfg.TelegramNotifyOnEvents = save;
      return(ok);
     }

   /// Fetch updates and queue the whitelisted commands. Called from OnTimer.
   void Poll(void)
     {
      if(!m_enabled)
         return;
      datetime now = XauNow();
      if(m_next_poll > 0 && now < m_next_poll)
         return;
      m_next_poll = now + (datetime)MathMax(1, m_cfg.TelegramPollingIntervalSeconds);
      if(m_pending_action != "" && now > m_pending_until)
        {
         m_pending_action = "";
         m_log.Info(XAU_T_TG, "pending confirmation expired");
        }
      string query = "timeout=0";
      if(m_offset > 0)
         query += "&offset=" + IntegerToString(m_offset + 1);
      string resp = "";
      if(!Api("getUpdates", query, resp))
        {
         m_log.Throttled(1, XAU_T_TG, "poll", "getUpdates failed: " + MaskToken(m_last_error), 300);
         // repeated auth failures (revoked token / wrong chat) must not
         // spin: after 10 consecutive errors the bot goes quiet for 10 min
         if(m_errors > 0 && m_errors % 10 == 0)
            m_next_poll = now + 600;
         return;
        }
      m_last_poll_ok = now;
      m_errors       = 0;
      if(StringFind(resp, "\"ok\":true") < 0)
        {
         m_errors++;
         m_last_error = "getUpdates returned ok=false: " + StringSubstr(resp, 0, 200);
         return;
        }
      // split on update boundaries and parse each chunk
      int pos = 0;
      string marker = "\"update_id\":";
      while(true)
        {
         int p = StringFind(resp, marker, pos);
         if(p < 0)
            break;
         int q = StringFind(resp, marker, p + 1);
         string chunk = (q < 0 ? StringSubstr(resp, p) : StringSubstr(resp, p, q - p));
         pos = (q < 0 ? StringLen(resp) : q);
         long uid = 0;
         if(!ExtractLong(chunk, "update_id", uid))
            continue;
         if(uid > m_offset)
           {
            m_offset = uid;
            if(m_store != NULL && m_store.Enabled())
               m_store.SetInt("tg_offset", m_offset);
           }
         long chat = 0;
         if(!ExtractChatId(chunk, chat))
            continue;
         long want = StringToInteger(m_cfg.TelegramChatID);
         string text = "";
         if(!ExtractString(chunk, "text", text))
            continue;                        // non text message: ignored
         m_recv++;
         if(chat != want)
           {
            m_rejected++;
            m_log.Throttled(1, XAU_T_TG, "chat",
                            StringFormat("message from chat %s ignored (not the configured chat)",
                                         IntegerToString(chat)), 300);
            continue;
           }
         ParseAndQueue(text);
        }
     }

   /// Sanitise + whitelist + tokenize one line of text.
   void ParseAndQueue(const string raw)
     {
      string s = raw;
      StringTrimRight(s);
      StringTrimLeft(s);
      int nl = StringFind(s, "\n");
      if(nl > 0)
         s = StringSubstr(s, 0, nl);            // "@mybot" suffixes and multi-line text
      if(StringLen(s) == 0 || StringGetCharacter(s, 0) != '/')
        {
         m_rejected++;
         Reply("Only /commands are accepted. Try /help");
         return;
        }
      // strip a trailing @botname
      int at = StringFind(s, "@");
      if(at > 0)
         s = StringSubstr(s, 0, at);
      if(StringLen(s) > 64)
        {
         m_rejected++;
         Reply("Command too long (max 64 characters)");
         return;
        }
      string lower = s;
      StringToLower(lower);
      string parts[];
      int n = StringSplit(lower, ' ', parts);
      if(n <= 0 || StringLen(parts[0]) < 2)
        {
         m_rejected++;
         Reply("Empty or malformed command. Try /help");
         return;
        }
      string name = StringSubstr(parts[0], 1);
      // allow only [a-z0-9_]
      for(int i = 0; i < StringLen(name); i++)
        {
         ushort c = StringGetCharacter(name, i);
         bool okc = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_';
         if(!okc)
           {
            m_rejected++;
            Reply("Rejected: illegal character in command name");
            return;
           }
        }
      if(!IsWhitelisted(name))
        {
         m_rejected++;
         m_log.Warn(XAU_T_TG, "unknown command rejected: /" + name);
         Reply("Unknown command /" + name + "\nAllowed: /help");
         return;
        }
      string args = "";
      for(int i = 1; i < n; i++)
        {
         string a = parts[i];
         StringTrimRight(a);
         StringTrimLeft(a);
         if(StringLen(a) == 0)
            continue;
         args += (StringLen(args) > 0 ? " " : "") + a;
        }
      if(StringLen(args) > 40)
        {
         m_rejected++;
         Reply("Rejected: too many arguments");
         return;
        }
      QueueCommand(name, args);
     }

   //--- engine facing queue ------------------------------------------
   int  PendingCommands(void) const { return(ArraySize(m_cmd)); }
   bool PopCommand(string &name, string &args)
     {
      if(ArraySize(m_cmd) == 0)
         return(false);
      name = m_cmd[0];
      args = m_args[0];
      int n = ArraySize(m_cmd);
      for(int i = 0; i < n - 1; i++)
        {
         m_cmd[i]  = m_cmd[i + 1];
         m_args[i] = m_args[i + 1];
        }
      ArrayResize(m_cmd, n - 1);
      ArrayResize(m_args, n - 1);
      return(true);
     }
   void ClearQueue(void)
     {
      ArrayResize(m_cmd, 0);
      ArrayResize(m_args, 0);
     }

   /// Destructive action bookkeeping, driven by the engine.
   void ArmConfirmation(const string action)
     {
      m_pending_action = action;
      m_pending_until  = XauNow() + XAU_TG_CONFIRM_SECONDS;
     }
   void DisarmConfirmation(void) { m_pending_action = ""; m_pending_until = 0; }

   /// Periodic status heartbeat (TelegramStatusIntervalMinutes > 0).
   void Heartbeat(const string text)
     {
      if(!m_enabled || m_cfg.TelegramStatusIntervalMinutes <= 0)
         return;
      datetime now = XauNow();
      if(m_next_notify > 0 && now < m_next_notify)
         return;
      m_next_notify = now + (datetime)(m_cfg.TelegramStatusIntervalMinutes * 60);
      Notify(text);
     }
  };

#endif // XAU_AVG_PRO_TELEGRAM_MQH
//+------------------------------------------------------------------+
