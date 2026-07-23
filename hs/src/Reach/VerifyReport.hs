module Reach.VerifyReport
  ( VerifyReport (..)
  , VerifyModeResult (..)
  , VerifyFailure (..)
  , SolPropertyResult (..)
  , SolModuleReport (..)
  , BoundaryAssumption (..)
  , VerifyReportAccum (..)
  , emptyVerifyReportAccum
  , vraAddMode
  , vraAddFailure
  , vraAddAssumption
  , mkVerifyReport
  , writeVerifyReport
  )
where

import Data.Aeson
import Data.Aeson.Encode.Pretty
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import Reach.OutputUtil

-- The shape of these records is a public interface: CI pipelines consume the
-- emitted verify.json, so field names must stay stable.

data VerifyFailure = VerifyFailure
  { vf_mode :: T.Text
  , vf_theorem :: T.Text
  , vf_msg :: Maybe T.Text
  , vf_at :: T.Text
  , vf_timeout :: Bool
  , vf_witness :: T.Text
  }
  deriving (Eq, Show)

instance ToJSON VerifyFailure where
  toJSON (VerifyFailure {..}) =
    object
      [ "vf_mode" .= vf_mode
      , "vf_theorem" .= vf_theorem
      , "vf_msg" .= vf_msg
      , "vf_at" .= vf_at
      , "vf_timeout" .= vf_timeout
      , "vf_witness" .= vf_witness
      ]

data VerifyModeResult = VerifyModeResult
  { vmr_mode :: T.Text
  , vmr_failures :: Int
  }
  deriving (Eq, Show)

instance ToJSON VerifyModeResult where
  toJSON (VerifyModeResult {..}) =
    object
      [ "vmr_mode" .= vmr_mode
      , "vmr_failures" .= vmr_failures
      ]

-- One SMTChecker target result for a companion Solidity module.
-- spr_status is one of: proven, violated, unknown, skipped, opaque-bytecode.
data SolPropertyResult = SolPropertyResult
  { spr_target :: T.Text
  , spr_status :: T.Text
  , spr_at :: T.Text
  , spr_counterexample :: Maybe T.Text
  }
  deriving (Eq, Ord, Show)

instance ToJSON SolPropertyResult where
  toJSON (SolPropertyResult {..}) =
    object
      [ "spr_target" .= spr_target
      , "spr_status" .= spr_status
      , "spr_at" .= spr_at
      , "spr_counterexample" .= spr_counterexample
      ]

-- One companion Solidity module (a `ContractCode` ETH source) and the
-- SMTChecker results for it. smr_srcAbs is bookkeeping for artifact copying
-- and is deliberately not serialized.
data SolModuleReport = SolModuleReport
  { smr_path :: T.Text
  , smr_contract :: T.Text
  , smr_solcVersion :: T.Text
  , smr_artifact :: Maybe T.Text
  , smr_properties :: [SolPropertyResult]
  , smr_srcAbs :: FilePath
  }
  deriving (Eq, Show)

instance ToJSON SolModuleReport where
  toJSON (SolModuleReport {..}) =
    object
      [ "smr_path" .= smr_path
      , "smr_contract" .= smr_contract
      , "smr_solcVersion" .= smr_solcVersion
      , "smr_artifact" .= smr_artifact
      , "smr_properties" .= smr_properties
      ]

-- A place where the verifier treats an external contract's behavior as
-- unconstrained (havoc). ba_kind is one of: remote, contractNew,
-- contractFromAddress.
data BoundaryAssumption = BoundaryAssumption
  { ba_at :: T.Text
  , ba_kind :: T.Text
  , ba_callee :: T.Text
  , ba_assumed :: T.Text
  }
  deriving (Eq, Ord, Show)

instance ToJSON BoundaryAssumption where
  toJSON (BoundaryAssumption {..}) =
    object
      [ "ba_at" .= ba_at
      , "ba_kind" .= ba_kind
      , "ba_callee" .= ba_callee
      , "ba_assumed" .= ba_assumed
      ]

data VerifyReportAccum = VerifyReportAccum
  { vra_modes :: [VerifyModeResult] -- newest first
  , vra_failures :: [VerifyFailure] -- newest first
  , vra_assumptions :: [BoundaryAssumption] -- newest first, deduplicated
  , vra_succ :: Int
  , vra_fail :: Int
  , vra_time :: Int
  , vra_reps :: Int
  }
  deriving (Eq, Show)

emptyVerifyReportAccum :: VerifyReportAccum
emptyVerifyReportAccum = VerifyReportAccum mempty mempty mempty 0 0 0 0

vraAddMode :: T.Text -> VerifyReportAccum -> VerifyReportAccum
vraAddMode m a = a {vra_modes = VerifyModeResult m 0 : vra_modes a}

vraAddFailure :: VerifyFailure -> VerifyReportAccum -> VerifyReportAccum
vraAddFailure f a =
  a
    { vra_failures = f : vra_failures a
    , vra_modes =
        case vra_modes a of
          [] -> []
          m : ms -> m {vmr_failures = vmr_failures m + 1} : ms
    }

-- The verifier visits the same program once per honesty mode (and possibly
-- per connector), so the same boundary is reported repeatedly; it is one
-- structural fact, so deduplicate.
vraAddAssumption :: BoundaryAssumption -> VerifyReportAccum -> VerifyReportAccum
vraAddAssumption b a =
  case elem b $ vra_assumptions a of
    True -> a
    False -> a {vra_assumptions = b : vra_assumptions a}

data VerifyReport = VerifyReport
  { vr_source :: T.Text
  , vr_app :: T.Text
  , vr_verified :: Bool
  , vr_theoremCount :: Int
  , vr_succeeded :: Int
  , vr_failed :: Int
  , vr_timedOut :: Int
  , vr_omittedRepeats :: Int
  , vr_modes :: [VerifyModeResult]
  , vr_failures :: [VerifyFailure]
  , vr_solidity :: [SolModuleReport]
  , vr_assumptions :: [BoundaryAssumption]
  }
  deriving (Eq, Show)

instance ToJSON VerifyReport where
  toJSON (VerifyReport {..}) =
    object
      [ "vr_source" .= vr_source
      , "vr_app" .= vr_app
      , "vr_verified" .= vr_verified
      , "vr_theoremCount" .= vr_theoremCount
      , "vr_succeeded" .= vr_succeeded
      , "vr_failed" .= vr_failed
      , "vr_timedOut" .= vr_timedOut
      , "vr_omittedRepeats" .= vr_omittedRepeats
      , "vr_modes" .= vr_modes
      , "vr_failures" .= vr_failures
      , "vr_solidity" .= vr_solidity
      , "vr_assumptions" .= vr_assumptions
      ]

mkVerifyReport :: T.Text -> T.Text -> Bool -> [SolModuleReport] -> VerifyReportAccum -> VerifyReport
mkVerifyReport vr_source vr_app vr_verified vr_solidity (VerifyReportAccum {..}) =
  VerifyReport
    { vr_theoremCount = vra_succ + vra_fail + vra_time
    , vr_succeeded = vra_succ
    , vr_failed = vra_fail
    , vr_timedOut = vra_time
    , vr_omittedRepeats = vra_reps
    , vr_modes = reverse vra_modes
    , vr_failures = reverse vra_failures
    , vr_assumptions = reverse vra_assumptions
    , ..
    }

writeVerifyReport :: FilePath -> VerifyReport -> IO ()
writeVerifyReport fp =
  atomicWriteFile BL.writeFile fp
    . encodePretty' (defConfig {confCompare = compare})
