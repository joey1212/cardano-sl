{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

-- | Methods of reporting different unhealthy behaviour to server.

module Pos.Sinbin.Reporting.Methods
       ( Reporter (..)

       , noReporter

       , MonadReporting (..)

         -- * Report single event.
       , reportError
       , reportInfo

       -- * Exception handling
       , reportOrLog
       , reportOrLogE
       , reportOrLogW

       ) where

import           Universum

import           Control.Exception (ErrorCall (..), Exception (..))
import           Pos.ReportServer.Report (ReportType (..))
import qualified Pos.Util.Log as Log

import           Pos.DB.Error (DBError (..))
import           Pos.Exception (CardanoFatalError)
import           Pos.Sinbin.Reporting.MemState ()
import           Pos.Util.Trace.Named (TraceNamed, logMessage)

-- | Encapsulates the sending of a report, with potential for side-effects.
newtype Reporter m = Reporter
    { runReporter :: ReportType -> m ()
    }

noReporter :: Applicative m => Reporter m
noReporter = Reporter (const (pure ()))

-- | Typeclass analgoue of 'Reporter', for those who are allergic to using
-- function arguments.
class MonadReporting m where
    report :: ReportType -> m ()

-- | Report some general information.
reportInfo :: MonadReporting m => Text -> m ()
reportInfo = report . RInfo

-- | Report «error», i. e. a situation when something is wrong with our
-- node, e. g. an assertion failed.
reportError :: MonadReporting m => Text -> m ()
reportError = report . RError

----------------------------------------------------------------------------
-- Exception handling
----------------------------------------------------------------------------

-- | Exception handler which reports (and logs) an exception or just
-- logs it. It reports only few types of exceptions which definitely
-- deserve attention. Other types are simply logged. It's suitable for
-- long-running workers which want to catch all exceptions and restart
-- after delay. If you are catching all exceptions somewhere, you most
-- likely want to use this handler (and maybe do something else).
--
-- NOTE: it doesn't rethrow an exception. If you are sure you need it,
-- you can rethrow it by yourself.
reportOrLog :: MonadReporting m => TraceNamed m -> Log.Severity -> Text -> SomeException -> m ()
reportOrLog logTrace severity prefix exc =
    case tryCast @CardanoFatalError <|> tryCast @ErrorCall <|> tryCast @DBError of
        Just msg -> reportError $ prefix <> msg
        Nothing  -> logMessage logTrace severity (prefix <> pretty exc)
  where
    tryCast ::
           forall e. Exception e
        => Maybe Text
    tryCast = toText . displayException <$> fromException @e exc

-- | A version of 'reportOrLog' which uses 'Error' severity.
reportOrLogE :: MonadReporting m => TraceNamed m -> Text -> SomeException -> m ()
reportOrLogE logTrace = reportOrLog logTrace Log.Error

-- | A version of 'reportOrLog' which uses 'Warning' severity.
reportOrLogW :: MonadReporting m => TraceNamed m -> Text -> SomeException -> m ()
reportOrLogW logTrace = reportOrLog logTrace Log.Warning