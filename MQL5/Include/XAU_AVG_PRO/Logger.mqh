//+------------------------------------------------------------------+
//|                                                       Logger.mqh |
//|          XAU_AVG_PRO v1.0.0 - structured, throttled event log   |
//|                                                                  |
//|  Every important event is written as:                            |
//|    2026.09.19 12:00:01 [TAG] XAUUSD mg=... cy=.. L=.. msg | kv  |
//|  Identical (key,tag) pairs are suppressed inside a throttle     |
//|  window so a stuck condition cannot flood the Journal.          |
//+------------------------------------------------------------------+
#ifndef XAU_AVG_PRO_LOGGER_MQH
#define XAU_AVG_PRO_LOGGER_MQH

#include "Types.mqh"

class CLogger
  {
private:
   int      m_level;
   bool     m_to_file;
   int      m_handle;
   string   m_file_name;
   string   m_symbol;
   long     m_magic;
   int      m_throttle;
   int      m_errors;
   bool     m_in_tester;
   string   m_keys[];
   datetime m_times[];
   string   m_context;      // "cy=27 L=2" appended to every line

   int FindKey(const string key)
     {
      for(int i = 0; i < ArraySize(m_keys); i++)
         if(m_keys[i] == key)
            return(i);
      return(-1);
   }
   void RememberKey(const string key, const datetime when)
     {
      int n = ArraySize(m_keys);
      if(n > 400)                              // bounded memory
        {
         ArrayResize(m_keys, 0);
         ArrayResize(m_times, 0);
         n = 0;
        }
      ArrayResize(m_keys, n + 1);
      ArrayResize(m_times, n + 1);
      m_keys[n]  = key;
      m_times[n] = when;
     }
   void WriteLine(const string line)
     {
      Print(line);
      if(m_to_file && m_handle != INVALID_HANDLE)
        {
         FileSeek(m_handle, 0, SEEK_END);
         FileWriteString(m_handle, line + "\n");
         FileFlush(m_handle);
        }
     }

public:
                     CLogger(void) : m_level(2), m_to_file(false), m_handle(INVALID_HANDLE),
                                     m_file_name(""), m_symbol(""), m_magic(0), m_throttle(60),
                                     m_errors(0), m_in_tester(false), m_context("")
     {
     }

   /// @param level     0 none, 1 errors, 2 info, 3 debug
   /// @param to_file   also mirror the journal into MQL5\Files
   /// @param throttle  suppression window for repeated identical keys
   bool Init(const int level, const bool to_file, const int throttle,
             const string symbol, const long magic)
     {
      m_level    = (int)XauClampI(level, 0, 3);
      m_throttle = (int)XauClampI(throttle, 0, 3600);
      m_symbol   = symbol;
      m_magic    = magic;
      m_in_tester = (bool)MQLInfoInteger(MQL_TESTER);
      m_handle   = INVALID_HANDLE;
      m_to_file  = false;
      // File logging is intentionally disabled in the Strategy Tester:
      // each tester pass runs in its own agent folder and a fast
      // optimisation run would generate gigabytes of files.
      if(to_file && !m_in_tester)
        {
         m_file_name = XAU_STATE_FILE + "_" + symbol + "_" + IntegerToString(magic) + ".log";
         m_handle = FileOpen(m_file_name, FILE_WRITE | FILE_READ | FILE_TXT | FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_ANSI);
         if(m_handle == INVALID_HANDLE)
           {
            PrintFormat("%s [%s] file log disabled, FileOpen('%s') failed err=%d",
                        XAU_EA_NAME, XAU_T_ERR, m_file_name, GetLastError());
            m_handle = INVALID_HANDLE;
           }
         else
            m_to_file = true;
        }
      return(true);
     }

   void Deinit(void)
     {
      if(m_handle != INVALID_HANDLE)
        {
         FileClose(m_handle);
         m_handle = INVALID_HANDLE;
        }
      m_to_file = false;
     }

   /// Cycle/layer stamp added to every line so a log file can be
   /// post-processed per cycle without parsing prices.
   void SetContext(const string context) { m_context = context; }
   int  ErrorsTotal(void)          const { return(m_errors); }
   int  Level(void)                const { return(m_level); }
   bool Want(const int level)      const { return(m_level >= level); }

   string Format(const string tag, const string msg)
     {
      string ctx = (StringLen(m_context) > 0 ? " " + m_context : "");
      return(StringFormat("%s [%s] %s mg=%d%s %s",
                          TimeToString(XauStampTime(), TIME_DATE | TIME_SECONDS),
                          tag, m_symbol, m_magic, ctx, msg));
     }

   void Raw(const string tag, const string msg)
     {
      WriteLine(Format(tag, msg));
     }

   void Error(const string tag, const string msg)
     {
      m_errors++;
      if(m_level >= 1)
         WriteLine(Format(tag, msg));
     }

   void Warn(const string tag, const string msg)
     {
      if(m_level >= 1)
         WriteLine(Format("[WARN]" + tag, msg));
     }

   void Info(const string tag, const string msg)
     {
      if(m_level >= 2)
         WriteLine(Format(tag, msg));
     }

   void Debug(const string tag, const string msg)
     {
      if(m_level >= 3)
         WriteLine(Format(tag, msg));
     }

   /// Log at most once per `seconds` for the same (tag,key) pair.
   /// Used for conditions that stay true for many ticks (spread too
   /// high, session closed, DD limit exceeded, ...).
   void Throttled(const int level, const string tag, const string key,
                  const string msg, const int seconds)
     {
      if(m_level < level)
         return;
      int win = (seconds > 0 ? seconds : m_throttle);
      int idx = FindKey(tag + "|" + key);
      datetime now = XauStampTime();
      if(idx >= 0 && (int)(now - m_times[idx]) < win)
         return;
      if(idx >= 0)
         m_times[idx] = now;
      else
         RememberKey(tag + "|" + key, now);
      WriteLine(Format(tag, msg));
     }
  };

#endif // XAU_AVG_PRO_LOGGER_MQH
//+------------------------------------------------------------------+
