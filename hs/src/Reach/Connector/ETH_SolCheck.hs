-- Companion-Solidity analysis: runs solc's built-in SMTChecker (CHC engine)
-- over hand-written `.sol` sources referenced via `ContractCode` and turns
-- the diagnostics into structured SolModuleReport values for verify.json.
--
-- This is deliberately a separate module from the production compile path in
-- Reach.Connector.ETH_solc: nothing here touches how contracts are compiled
-- for deployment.
--
-- The registry is process-global because `ContractCode` values are resolved
-- deep inside evaluation (via conCompileCode, a static field of the
-- Connector record) while enforcement and reporting happen at the compiler
-- driver level; reachc compiles one source per process, and apps compile
-- sequentially, so the driver drains the registry per app.
module Reach.Connector.ETH_SolCheck
  ( CompanionCheckLevel (..)
  , parseCompanionCheckLevel
  , SolCheckCfg (..)
  , solCheckSetCfg
  , solCheckRegisterSol
  , solCheckRegisterOpaque
  , solCheckTakeModules
  , solCheckSummary
  , solCheckFatalProps
  , solCheckFatalMsg
  , SolcDiag (..)
  , solCheckClassify
  , solCheckRequest
  )
where

import Data.Aeson as Aeson
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.IORef
import Data.List (intercalate, sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.String
import qualified Data.Text as T
import Reach.Util
import Reach.VerifyReport
import System.Directory
import System.FilePath
import System.IO.Temp
import System.IO.Unsafe (unsafePerformIO)
import System.Process.ByteString

data CompanionCheckLevel
  = CCL_Require
  | CCL_Warn
  | CCL_Off
  deriving (Eq, Show)

parseCompanionCheckLevel :: String -> Maybe CompanionCheckLevel
parseCompanionCheckLevel = \case
  "require" -> Just CCL_Require
  "warn" -> Just CCL_Warn
  "off" -> Just CCL_Off
  _ -> Nothing

data SolCheckCfg = SolCheckCfg
  { scc_enabled :: Bool
  , scc_timeout :: Integer
  , scc_noSolver :: Bool
  }

defaultSolCheckCfg :: SolCheckCfg
defaultSolCheckCfg = SolCheckCfg False 0 False

{-# NOINLINE solCheckCfgR #-}
solCheckCfgR :: IORef SolCheckCfg
solCheckCfgR = unsafePerformIO $ newIORef defaultSolCheckCfg

{-# NOINLINE solCheckRegR #-}
solCheckRegR :: IORef (M.Map (FilePath, String) SolModuleReport)
solCheckRegR = unsafePerformIO $ newIORef mempty

{-# NOINLINE solCheckProbeR #-}
solCheckProbeR :: IORef (Maybe Bool)
solCheckProbeR = unsafePerformIO $ newIORef Nothing

{-# NOINLINE solCheckVersionR #-}
solCheckVersionR :: IORef (Maybe T.Text)
solCheckVersionR = unsafePerformIO $ newIORef Nothing

solCheckSetCfg :: SolCheckCfg -> IO ()
solCheckSetCfg = writeIORef solCheckCfgR

data SolcDiag = SolcDiag
  { sd_code :: T.Text
  , sd_severity :: T.Text
  , sd_message :: T.Text
  , sd_formatted :: T.Text
  }
  deriving (Eq, Show)

instance FromJSON SolcDiag where
  parseJSON = withObject "SolcDiag" $ \o -> do
    sd_code <- o .:? "errorCode" .!= ""
    sd_severity <- o .:? "severity" .!= ""
    sd_message <- o .:? "message" .!= ""
    sd_formatted <- o .:? "formattedMessage" .!= ""
    return $ SolcDiag {..}

newtype SolcDiags = SolcDiags [SolcDiag]

instance FromJSON SolcDiags where
  parseJSON = withObject "SolcDiags" $ \o -> do
    ds <- o .:? "errors" .!= []
    return $ SolcDiags ds

-- The standard-json request for an SMTChecker-only run: no code generation is
-- requested, only model-checker diagnostics. The source key is the path as
-- written so diagnostic locations stay relative and reproducible.
solCheckRequest :: Integer -> FilePath -> Value
solCheckRequest tmo solf =
  object
    [ ("language", "Solidity")
    , ( "sources"
      , object
          [ ( fromString solf
            , object [("urls", toJSONList [solf])]
            )
          ]
      )
    , ( "settings"
      , object
          [ ( "modelChecker"
            , object
                [ ("engine", "chc")
                , ("targets", toJSONList (["assert", "overflow", "underflow", "divByZero"] :: [String]))
                , ("timeout", toJSON tmo)
                , ("invariants", toJSONList (["contract"] :: [String]))
                , ("showUnproved", toJSON True)
                , ("showProvedSafe", toJSON True)
                ]
            )
          , ( "outputSelection"
            , object [("*", object [("*", toJSONList (["abi"] :: [String]))])]
            )
          ]
      )
    ]

-- Diagnostic codes that are informational summaries, not per-property results
summaryCodes :: [T.Text]
summaryCodes = ["1391", "1180", "5840"]

-- Turn solc model-checker diagnostics into per-property results.
-- CHC reports: "CHC: <target> check is safe!" (proven),
-- "CHC: <target> happens here." (violated, with counterexample),
-- "CHC: <target> might happen here." (unproved).
solCheckClassify :: [SolcDiag] -> [SolPropertyResult]
solCheckClassify ds = sortOn (\p -> (spr_at p, spr_target p, spr_status p)) $ mapMaybe go ds
  where
    go (SolcDiag {..}) =
      case sd_code `elem` summaryCodes of
        True -> Nothing
        False ->
          case T.stripPrefix "CHC: " sd_message of
            Nothing -> Nothing
            Just msg -> Just $ classify msg
      where
        classify msg
          | Just t <- T.stripSuffix " check is safe!" (firstLine msg) =
            res t "proven" Nothing
          | (t, rest) <- T.breakOn " might happen here" msg
            , rest /= "" =
            res t "unknown" Nothing
          | (t, rest) <- T.breakOn " happens here" msg
            , rest /= "" =
            res t "violated" (Just sd_message)
          | otherwise =
            res (firstLine msg) "unknown" Nothing
        res t st ce =
          SolPropertyResult
            { spr_target = t
            , spr_status = st
            , spr_at = diagAt sd_formatted
            , spr_counterexample = ce
            }
    firstLine = T.takeWhile (/= '\n')

-- Extract "path:line:col" from the "--> path:line:col:" arrow line solc puts
-- in formatted messages.
diagAt :: T.Text -> T.Text
diagAt fm =
  case T.breakOn "--> " fm of
    (_, "") -> ""
    (_, rest) ->
      T.dropWhileEnd (== ':') $ T.takeWhile (/= '\n') $ T.drop 4 rest

solCheckRunOn :: Integer -> FilePath -> IO (Either String [SolcDiag])
solCheckRunOn tmo solf = do
  let bp = takeDirectory solf
  (_ec, stdout, stderr) <-
    readProcessWithExitCode "solc" ["--allow-paths", bp, "--standard-json"] $
      LB.toStrict $ encode $ solCheckRequest tmo solf
  case eitherDecodeStrict stdout of
    Right (SolcDiags ds) -> return $ Right ds
    Left m ->
      return $
        Left $
          "solc --standard-json produced unparseable output: " <> m
            <> "\nSTDERR:\n"
            <> bunpack stderr

-- Whether the local solc can actually discharge CHC queries (it loads an SMT
-- solver like z3 dynamically; without one, everything is unproved). Probed
-- once per process with a trivially violable assert.
solCheckProbe :: Bool -> IO Bool
solCheckProbe noSolver =
  case noSolver of
    True -> return False
    False ->
      readIORef solCheckProbeR >>= \case
        Just b -> return b
        Nothing -> do
          b <-
            withSystemTempDirectory "reach-solcheck" $ \d -> do
              let f = d </> "ReachSolverProbe.sol"
              writeFile f $
                unlines
                  [ "// SPDX-License-Identifier: MIT"
                  , "pragma solidity ^0.8.0;"
                  , "contract ReachSolverProbe {"
                  , "  function f(uint x) public pure { assert(x != 42); }"
                  , "}"
                  ]
              solCheckRunOn 10000 f >>= \case
                Left _ -> return False
                Right ds ->
                  return $ any ((== "violated") . spr_status) $ solCheckClassify ds
          writeIORef solCheckProbeR $ Just b
          return b

solCheckSolcVersion :: IO T.Text
solCheckSolcVersion =
  readIORef solCheckVersionR >>= \case
    Just v -> return v
    Nothing -> do
      (_ec, stdout, _stderr) <- readProcessWithExitCode "solc" ["--version"] ""
      let ls = T.lines $ s2t $ bunpack stdout
      let v =
            case mapMaybe (T.stripPrefix "Version: ") ls of
              v' : _ -> v'
              [] -> ""
      writeIORef solCheckVersionR $ Just v
      return v

mkModule :: FilePath -> String -> FilePath -> [SolPropertyResult] -> T.Text -> SolModuleReport
mkModule solf cn ka props ver =
  SolModuleReport
    { smr_path = s2t solf
    , smr_contract = s2t cn
    , smr_solcVersion = ver
    , smr_artifact = Nothing
    , smr_properties = props
    , smr_srcAbs = ka
    }

-- Record a companion `.sol` source and analyze it. Called (via the ETH
-- connector's ContractCode resolution) with the current directory set to the
-- referencing source file's directory, so `solf` resolves as written.
solCheckRegisterSol :: FilePath -> String -> IO ()
solCheckRegisterSol solf cn = do
  SolCheckCfg {..} <- readIORef solCheckCfgR
  case scc_enabled of
    False -> return ()
    True -> do
      ka <- canonicalizePath solf
      let k = (ka, cn)
      reg <- readIORef solCheckRegR
      case M.member k reg of
        True -> return ()
        False -> do
          ver <- solCheckSolcVersion
          ok <- solCheckProbe scc_noSolver
          props <-
            case ok of
              False ->
                return [SolPropertyResult "companion analysis" "skipped" "" Nothing]
              True ->
                solCheckRunOn scc_timeout solf >>= \case
                  Left err ->
                    return [SolPropertyResult "companion analysis" "unknown" "" (Just $ s2t err)]
                  Right ds -> return $ solCheckClassify ds
          modifyIORef solCheckRegR $ M.insert k $ mkModule solf cn ka props ver

-- Record a pre-compiled (.bin / .json) companion: we cannot analyze bytecode.
solCheckRegisterOpaque :: FilePath -> Maybe String -> IO ()
solCheckRegisterOpaque fp mcn = do
  SolCheckCfg {..} <- readIORef solCheckCfgR
  case scc_enabled of
    False -> return ()
    True -> do
      ka <- canonicalizePath fp
      let cn = fromMaybe "" mcn
      let k = (ka, cn)
      let props = [SolPropertyResult "companion analysis" "opaque-bytecode" "" Nothing]
      modifyIORef solCheckRegR $ M.insertWith (\_new old -> old) k $ mkModule fp cn ka props ""

-- Drain the registry (one app's worth of ContractCode resolutions).
solCheckTakeModules :: IO [SolModuleReport]
solCheckTakeModules = do
  reg <- readIORef solCheckRegR
  writeIORef solCheckRegR mempty
  return $ sortOn (\m -> (smr_path m, smr_contract m)) $ M.elems reg

solCheckSummary :: SolModuleReport -> String
solCheckSummary (SolModuleReport {..}) =
  "Companion Solidity " <> T.unpack smr_path <> lbl <> ": " <> body
  where
    lbl = case smr_contract of
      "" -> ""
      cn -> ":" <> T.unpack cn
    sts = map spr_status smr_properties
    body =
      case elem "opaque-bytecode" sts of
        True -> "opaque bytecode; not analyzed"
        False ->
          case elem "skipped" sts of
            True -> "analysis skipped (no SMT solver available to solc)"
            False -> intercalate ", " $ map cnt ["proven", "violated", "unknown"]
    cnt s = show (length $ filter (== s2t s) sts) <> " " <> s

-- Which of a module's results are fatal for this compile. A violated property
-- is fatal whenever the artifact set claims verification (--sol) or the level
-- demands it; everything short of proven is fatal at level `require`.
solCheckFatalProps :: CompanionCheckLevel -> Bool -> SolModuleReport -> [SolPropertyResult]
solCheckFatalProps lvl solOnly (SolModuleReport {..}) =
  filter bad smr_properties
  where
    bad (SolPropertyResult {..}) =
      case spr_status of
        "violated" -> solOnly || lvl == CCL_Require
        "proven" -> False
        _ -> lvl == CCL_Require

solCheckFatalMsg :: [(SolModuleReport, SolPropertyResult)] -> String
solCheckFatalMsg fs =
  intercalate "\n" $ "reachc: companion Solidity verification failed:" : concatMap f fs
  where
    f (SolModuleReport {..}, SolPropertyResult {..}) =
      [ "  " <> T.unpack smr_path <> ": " <> T.unpack spr_target
          <> " is "
          <> T.unpack spr_status
          <> at'
      ]
        <> ce'
        <> hint spr_status
      where
        at' = case spr_at of
          "" -> ""
          x -> " at " <> T.unpack x
        ce' = case spr_counterexample of
          Nothing -> []
          Just c -> map ("    " <>) $ lines $ T.unpack c
        hint = \case
          "skipped" ->
            ["    (solc found no SMT solver; install z3 at the DEPS-pinned version, or pass --companion-check=warn to record this as an open assumption)"]
          "opaque-bytecode" ->
            ["    (pre-compiled bytecode cannot be analyzed; reference the .sol source instead, or pass --companion-check=warn)"]
          _ -> []
