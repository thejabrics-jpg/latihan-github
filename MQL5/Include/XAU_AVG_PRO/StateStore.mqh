//+------------------------------------------------------------------+
//|                                                   StateStore.mqh |
//|  XAU_AVG_PRO v1.0.0 - persistent key/value state (restart safe) |
//|                                                                  |
//|  Format: plain text "key=value" lines inside MQL5\Files, one    |
//|  file per symbol+magic pair so that several EA instances never  |
//|  read each other's state.                                         |
//|                                                                  |
//|  Design rules:                                                   |
//|   - the file is a CACHE of facts that are also derivable from   |
//|     the account; positions remain the source of truth           |
//|   - writing is atomic (tmp file + FileMove with FILE_REWRITE)    |
//|   - in the Strategy Tester persistence is disabled: the tester   |
//|     agent folder is not a stable location and the simulated      |
//|     account is rebuilt for every pass                            |
//+------------------------------------------------------------------+
#ifndef XAU_AVG_PRO_STATESTORE_MQH
#define XAU_AVG_PRO_STATESTORE_MQH

#include "Types.mqh"

class CStateStore
  {
private:
   string   m_file;
   bool     m_enabled;
   bool     m_dirty;
   bool     m_loaded;
   bool     m_exists_on_disk;
   string   m_keys[];
   string   m_vals[];
   int      m_errors;

   int Find(const string key)
     {
      for(int i = 0; i < ArraySize(m_keys); i++)
         if(m_keys[i] == key)
            return(i);
      return(-1);
     }
   void PutRaw(const string key, const string value)
     {
      int i = Find(key);
      if(i >= 0)
        {
         if(m_vals[i] != value)
           {
            m_vals[i] = value;
            m_dirty   = true;
           }
         return;
        }
      int n = ArraySize(m_keys);
      ArrayResize(m_keys, n + 1);
      ArrayResize(m_vals, n + 1);
      m_keys[n] = key;
      m_vals[n] = value;
      m_dirty   = true;
     }
   string FileNameFor(const string symbol, const long magic)
     {
      string s = symbol;
      StringReplace(s, ".", "_");     // XAUUSD.a -> XAUUSD_a
      return(XAU_STATE_FILE + "_" + s + "_" + IntegerToString(magic) + ".dat");
     }

public:
                     CStateStore(void) : m_file(""), m_enabled(false), m_dirty(false), m_loaded(false),
                                         m_exists_on_disk(false), m_errors(0)
     {
     }

   bool Init(const string symbol, const long magic, const bool allow_persist)
     {
      bool in_tester = (bool)MQLInfoInteger(MQL_TESTER);
      m_enabled = (allow_persist && !in_tester);
      m_file    = FileNameFor(symbol, magic);
      m_loaded  = false;
      return(m_enabled);
     }

   bool Enabled(void)          const { return(m_enabled); }
   bool Dirty(void)            const { return(m_dirty); }
   bool FileExists(void)       const { return(m_exists_on_disk); }
   int  Errors(void)           const { return(m_errors); }
   string FileName(void)       const { return(m_file); }

   /// Read the file into memory. Returns false when there is no file
   /// (first run) - that is not an error.
   bool Load(void)
     {
      m_loaded = false;
      m_exists_on_disk = false;
      ArrayResize(m_keys, 0);
      ArrayResize(m_vals, 0);
      if(!m_enabled)
         return(false);
      if(!FileIsExist(m_file))
         return(false);
      int h = FileOpen(m_file, FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE);
      if(h == INVALID_HANDLE)
        {
         m_errors++;
         return(false);
        }
      m_exists_on_disk = true;
      while(!FileIsEnding(h))
        {
         string line = FileReadString(h);
         line = StringTrimLeft(StringTrimRight(line));
         if(StringLen(line) == 0 || StringGetCharacter(line, 0) == '#')
            continue;
         int p = StringFind(line, "=");
         if(p <= 0)
            continue;
         string k = StringTrimRight(StringSubstr(line, 0, p));
         string v = StringTrimLeft(StringSubstr(line, p + 1));
         PutRaw(k, v);
        }
      FileClose(h);
      m_loaded = true;
      m_dirty  = false;
      return(true);
     }

   /// Persist atomically. Called when Dirty() is true and either a
   /// trade action completed or the save interval elapsed.
   bool Save(void)
     {
      if(!m_enabled || !m_dirty)
         return(true);
      string body = StringFormat("#%s state v%d\n", XAU_EA_NAME, XAU_STATE_FORMAT);
      for(int i = 0; i < ArraySize(m_keys); i++)
         body += m_keys[i] + "=" + m_vals[i] + "\n";
      string tmp = m_file + ".tmp";
      int h = FileOpen(tmp, FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(h == INVALID_HANDLE)
        {
         m_errors++;
         return(false);
        }
      FileWriteString(h, body);
      FileFlush(h);
      FileClose(h);
      if(!FileMove(tmp, 0, m_file, FILE_REWRITE))
        {
         m_errors++;
         FileDelete(tmp);
         return(false);
        }
      m_dirty          = false;
      m_loaded         = true;
      m_exists_on_disk = true;
      return(true);
     }

   //--- typed setters -----------------------------------------------
   void SetStr(const string key, const string value) { PutRaw(key, value); }
   void SetDbl(const string key, const double value)
     {
      PutRaw(key, DoubleToString(value, 8));
     }
   void SetInt(const string key, const long value)
     {
      PutRaw(key, IntegerToString(value));
     }
   void SetBool(const string key, const bool value)
     {
      PutRaw(key, (value ? "1" : "0"));
     }
   void SetTime(const string key, const datetime value)
     {
      PutRaw(key, IntegerToString((long)value));
     }

   //--- typed getters -------------------------------------------------
   bool Has(const string key) const { return(Find(key) >= 0); }
   bool GetStr(const string key, string &out)
     {
      int i = Find(key);
      if(i < 0) return(false);
      out = m_vals[i];
      return(true);
     }
   bool GetDbl(const string key, double &out)
     {
      int i = Find(key);
      if(i < 0) return(false);
      out = StringToDouble(m_vals[i]);
      return(true);
     }
   bool GetInt(const string key, long &out)
     {
      int i = Find(key);
      if(i < 0) return(false);
      out = StringToInteger(m_vals[i]);
      return(true);
     }
   bool GetBool(const string key, bool &out)
     {
      int i = Find(key);
      if(i < 0) return(false);
      out = (m_vals[i] == "1" || m_vals[i] == "true");
      return(true);
     }
   bool GetTime(const string key, datetime &out)
     {
      long v = 0;
      if(!GetInt(key, v)) return(false);
      out = (datetime)v;
      return(true);
     }
   /// Get with default when the key is missing (first run / fresh VPS).
   double GetDblOr(const string key, const double def)
     {
      double v = def;
      return(GetDbl(key, v) ? v : def);
     }
   long GetIntOr(const string key, const long def)
     {
      long v = def;
      return(GetInt(key, v) ? v : def);
     }
   bool GetBoolOr(const string key, const bool def)
     {
      bool v = def;
      return(GetBool(key, v) ? v : def);
     }
   datetime GetTimeOr(const string key, const datetime def)
     {
      long v = (long)def;
      return(GetInt(key, v) ? (datetime)v : def);
     }

   void Erase(const string key)
     {
      int i = Find(key);
      if(i < 0)
         return;
      int n = ArraySize(m_keys);
      for(int k = i; k < n - 1; k++)
        {
         m_keys[k] = m_keys[k + 1];
         m_vals[k] = m_vals[k + 1];
        }
      ArrayResize(m_keys, n - 1);
      ArrayResize(m_vals, n - 1);
      m_dirty = true;
     }

   /// Delete every "prefix*" key - used by /resetparams and by tests.
   int ErasePrefix(const string prefix)
     {
      int removed = 0;
      for(int i = ArraySize(m_keys) - 1; i >= 0; i--)
         if(StringFind(m_keys[i], prefix) == 0)
           {
            Erase(m_keys[i]);
            removed++;
           }
      return(removed);
     }

   string Dump(void)
     {
      string s = "";
      for(int i = 0; i < ArraySize(m_keys); i++)
        {
         string v = m_vals[i];
         // never leak credentials even if somebody stored them by accident
         if(StringFind(m_keys[i], "token") >= 0)
            v = "***";
         s += m_keys[i] + "=" + v + "\n";
         if(i > 60)
           {
            s += "...(truncated)";
            break;
           }
        }
      return(s);
     }
  };

#endif // XAU_AVG_PRO_STATESTORE_MQH
//+------------------------------------------------------------------+
