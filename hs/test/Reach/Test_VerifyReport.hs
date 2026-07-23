module Reach.Test_VerifyReport
  ( spec_verifyReportShape
  , spec_solCommandLine
  )
where

import Data.Aeson (Value, object, toJSON, (.=))
import Reach.CommandLine
import Reach.VerifyReport
import System.Environment (withArgs)
import Test.Hspec

-- The verify.json field names are a public interface consumed by CI
-- pipelines; this spec locks them.
spec_verifyReportShape :: Spec
spec_verifyReportShape = describe "VerifyReport JSON shape" $ do
  it "serializes with stable field names" $ do
    let acc0 = emptyVerifyReportAccum {vra_succ = 5, vra_fail = 1, vra_time = 0, vra_reps = 2}
    let acc1 = vraAddMode "generic connector: ALL participants are honest" acc0
    let f =
          VerifyFailure
            { vf_mode = "ALL participants are honest"
            , vf_theorem = "assert"
            , vf_msg = Just "x is small"
            , vf_at = "./x.rsh:14:9:application"
            , vf_timeout = False
            , vf_witness = "Verification failed: ..."
            }
    let acc2 = vraAddFailure f acc1
    let ba =
          BoundaryAssumption
            { ba_at = "./x.rsh:20:11:application"
            , ba_kind = "remote"
            , ba_callee = "f"
            , ba_assumed = "havoc: UInt"
            }
    -- adding the same assumption twice must deduplicate
    let acc = vraAddAssumption ba $ vraAddAssumption ba acc2
    let smr =
          SolModuleReport
            { smr_path = "vault.sol"
            , smr_contract = "Vault"
            , smr_solcVersion = "0.8.26"
            , smr_artifact = Just "x.main.companion.Vault.sol"
            , smr_properties =
                [ SolPropertyResult
                    { spr_target = "Assertion violation"
                    , spr_status = "proven"
                    , spr_at = "vault.sol:9:5"
                    , spr_counterexample = Nothing
                    }
                ]
            , smr_srcAbs = "/abs/vault.sol"
            }
    let vr = mkVerifyReport "x.rsh" "main" False [smr] acc
    let expected :: Value
        expected =
          object
            [ "vr_source" .= ("x.rsh" :: String)
            , "vr_app" .= ("main" :: String)
            , "vr_verified" .= False
            , "vr_theoremCount" .= (6 :: Int)
            , "vr_succeeded" .= (5 :: Int)
            , "vr_failed" .= (1 :: Int)
            , "vr_timedOut" .= (0 :: Int)
            , "vr_omittedRepeats" .= (2 :: Int)
            , "vr_modes"
                .= [ object
                       [ "vmr_mode" .= ("generic connector: ALL participants are honest" :: String)
                       , "vmr_failures" .= (1 :: Int)
                       ]
                   ]
            , "vr_failures"
                .= [ object
                       [ "vf_mode" .= ("ALL participants are honest" :: String)
                       , "vf_theorem" .= ("assert" :: String)
                       , "vf_msg" .= ("x is small" :: String)
                       , "vf_at" .= ("./x.rsh:14:9:application" :: String)
                       , "vf_timeout" .= False
                       , "vf_witness" .= ("Verification failed: ..." :: String)
                       ]
                   ]
            , "vr_solidity"
                .= [ object
                       [ "smr_path" .= ("vault.sol" :: String)
                       , "smr_contract" .= ("Vault" :: String)
                       , "smr_solcVersion" .= ("0.8.26" :: String)
                       , "smr_artifact" .= ("x.main.companion.Vault.sol" :: String)
                       , "smr_properties"
                           .= [ object
                                  [ "spr_target" .= ("Assertion violation" :: String)
                                  , "spr_status" .= ("proven" :: String)
                                  , "spr_at" .= ("vault.sol:9:5" :: String)
                                  , "spr_counterexample" .= (Nothing :: Maybe String)
                                  ]
                              ]
                       ]
                   ]
            , "vr_assumptions"
                .= [ object
                       [ "ba_at" .= ("./x.rsh:20:11:application" :: String)
                       , "ba_kind" .= ("remote" :: String)
                       , "ba_callee" .= ("f" :: String)
                       , "ba_assumed" .= ("havoc: UInt" :: String)
                       ]
                   ]
            ]
    toJSON vr `shouldBe` expected

spec_solCommandLine :: Spec
spec_solCommandLine = describe "reachc --sol flag" $ do
  it "sets co_solOnly and composes with --intermediate-files" $ do
    cta <- withArgs ["--sol", "--intermediate-files", "x.rsh"] $ getCompilerArgs "test"
    let co = cta_co cta
    co_solOnly co `shouldBe` True
    co_intermediateFiles co `shouldBe` True
    co_source co `shouldBe` "x.rsh"
  it "defaults to off" $ do
    cta <- withArgs ["x.rsh"] $ getCompilerArgs "test"
    co_solOnly (cta_co cta) `shouldBe` False
    co_verifyReport (cta_co cta) `shouldBe` False
    co_companionCheck (cta_co cta) `shouldBe` Nothing
    co_companionNoSolver (cta_co cta) `shouldBe` False
  it "parses --companion-check" $ do
    cta <- withArgs ["--sol", "--companion-check", "warn", "x.rsh"] $ getCompilerArgs "test"
    co_companionCheck (cta_co cta) `shouldBe` Just "warn"
