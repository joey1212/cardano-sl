{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Pos.Infra.Reporting.Http
       ( sendReport
       , sendReportNodeImpl
       , reportNode
       ) where

import           Universum

import           Control.Exception (Exception (..))
import           Control.Exception.Safe (catchAny, try)
import           Data.Aeson (encode)
import qualified Data.List.NonEmpty as NE
import           Data.Time.Clock (getCurrentTime)
import           Data.Version (showVersion)
import           Formatting (sformat, shown, string, (%))
import           Network.HTTP.Client (httpLbs, newManager, parseUrlThrow)
import qualified Network.HTTP.Client.MultipartFormData as Form
import           Network.HTTP.Client.TLS (tlsManagerSettings)
import           Pos.ReportServer.Report (BackendVersion (..), ReportInfo (..),
                     ReportType (..), Version (..))
import           System.Info (arch, os)

import           Paths_cardano_sl_infra (version)
import           Pos.Crypto (ProtocolMagic (..), getProtocolMagic)
import           Pos.Infra.Reporting.Exceptions (ReportingError (..))
import           Pos.Util.CompileInfo (CompileTimeInfo)
import           Pos.Util.Trace (Severity (..), Trace, traceWith)
import           Pos.Util.Util ((<//>))


-- | Given optional log file and report type, sends reports to URI
-- asked. The file, if given, must of course exist and be openable/readable
-- by this process. You probably want to use a temporary file.
-- Report server URI should be in form like
-- "http(s)://host:port/" without specified endpoint.
sendReport
    :: ProtocolMagic
    -> CompileTimeInfo
    -> ReportType
    -> Text             -- ^ Application name
    -> String           -- ^ URI of the report server
    -> IO ()
sendReport pm compileInfo reportType appName reportServerUri = do
    curTime <- getCurrentTime
    rq0 <- parseUrlThrow $ reportServerUri <//> "report"
    let payloadPart =
            Form.partLBS "payload"
            (encode $ mkReportInfo curTime)
    -- If performance will ever be a concern, moving to a global manager
    -- should help a lot.
    reportManager <- newManager tlsManagerSettings

    -- Assemble the `Request` out of the Form data.
    rq <- Form.formDataBody [payloadPart] rq0

    -- Actually perform the HTTP `Request`.
    e  <- try $ httpLbs rq reportManager
    whenLeft e $ \(e' :: SomeException) -> throwM $ SendingError e'
  where
    mkReportInfo curTime =
        ReportInfo
        { rApplication = appName
        -- We are using version of 'cardano-sl-infra' here. We agreed
        -- that the version of 'cardano-sl' and it subpackages should
        -- be same.
        , rVersion = BackendVersion . Version . fromString . showVersion $ version
        , rBuild = pretty compileInfo
        , rOS = toText (os <> "-" <> arch)
        , rMagic = getProtocolMagic pm
        , rDate = curTime
        , rReportType = reportType
        }

-- | Common code across node sending: tries to send logs to at least one
-- reporting server.
sendReportNodeImpl
    :: Trace IO (Severity, Text)
    -> ProtocolMagic
    -> CompileTimeInfo
    -> [Text]         -- ^ Report server URIs
    -> ReportType
    -> IO ()
sendReportNodeImpl logTrace protocolMagic compileInfo servers reportType = do
    if null servers
    then onNoServers
    else do
        errors <-
            fmap lefts $ forM servers $
            try . sendReport protocolMagic compileInfo reportType "cardano-node" . toString
        whenNotNull errors $ throwSE . NE.head
  where
    onNoServers =
        traceWith logTrace
            (Info
            , "sendReportNodeImpl: not sending report " <>
              "because no reporting servers are specified"
            )
    throwSE (e :: SomeException) = throwM e

-- | Send a report to a given list of servers.
--
-- Note that we are catching all synchronous exceptions, but don't
-- catch async ones ('catchAny' is from safe-exceptions)
-- If reporting is broken, we don't want it to affect anything else.
-- FIXME then perhaps all of this reporting-related IO should be done in an
-- isolated thread, rather than inline at the call site.
reportNode
    :: Trace IO (Severity, Text)
    -> ProtocolMagic
    -> CompileTimeInfo
    -> [Text]         -- ^ Servers
    -> ReportType
    -> IO ()
reportNode logTrace protocolMagic compileInfo reportServers reportType =
    reportNodeDo `catchAny` handler
  where
    reportNodeDo = do
        logReportType reportType
        sendReportNodeImpl logTrace protocolMagic compileInfo reportServers reportType

    handler :: SomeException -> IO ()
    handler e =
        traceWith logTrace $ (,) Error $
        sformat ("Didn't manage to report "%shown%
                 " because of exception '"%string%"' raised while sending")
        reportType (displayException e)

    logReportType :: ReportType -> IO ()
    logReportType (RCrash i) = traceWith logTrace (Error, "Reporting crash with code " <> show i)
    logReportType (RError reason) =
        traceWith logTrace (Error, "Reporting error with reason \"" <> reason <> "\"")
    logReportType (RMisbehavior True reason) =
        traceWith logTrace (Error, "Reporting critical misbehavior with reason \"" <> reason <> "\"")
    logReportType (RMisbehavior False reason) =
        traceWith logTrace (Warning, "Reporting non-critical misbehavior with reason \"" <> reason <> "\"")
    logReportType (RInfo text) =
        traceWith logTrace (Info, "Reporting info with text \"" <> text <> "\"")
    logReportType (RCustomReport{}) =
        traceWith logTrace (Info, "Reporting custom report")
