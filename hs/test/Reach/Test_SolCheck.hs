module Reach.Test_SolCheck
  ( spec_solCheckClassify
  , spec_solCheckLevels
  )
where

import Data.Aeson (encode)
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.List (isInfixOf)
import qualified Data.Text as T
import Reach.Connector.ETH_SolCheck
import Reach.VerifyReport
import Test.Hspec

-- Canned solc 0.8.26 model-checker diagnostics (shapes captured from a real
-- `solc --standard-json` run with modelChecker engine=chc).
provenDiag :: SolcDiag
provenDiag =
  SolcDiag
    { sd_code = "9576"
    , sd_severity = "info"
    , sd_message = "CHC: Assertion violation check is safe!"
    , sd_formatted = "Info: CHC: Assertion violation check is safe!\n --> Good.sol:9:5:\n  |\n9 |     assert(total >= before);\n  |     ^^^^^^^^^^^^^^^^^^^^^^^\n\n"
    }

violatedDiag :: SolcDiag
violatedDiag =
  SolcDiag
    { sd_code = "6328"
    , sd_severity = "warning"
    , sd_message = "CHC: Assertion violation happens here.\nCounterexample:\n\nx = 42\n\nTransaction trace:\nProbe.constructor()\nProbe.f(42)"
    , sd_formatted = "Warning: CHC: Assertion violation happens here.\nCounterexample:\n\nx = 42\n\nTransaction trace:\nProbe.constructor()\nProbe.f(42)\n --> Probe.sol:5:5:\n  |\n5 |     assert(x != 42);\n  |     ^^^^^^^^^^^^^^^\n\n"
    }

unknownDiag :: SolcDiag
unknownDiag =
  SolcDiag
    { sd_code = "6328"
    , sd_severity = "warning"
    , sd_message = "CHC: Assertion violation might happen here."
    , sd_formatted = "Warning: CHC: Assertion violation might happen here.\n --> Hard.sol:6:7:\n  |\n6 |       assert(x*x*x + y*y*y != 22222222);\n  |       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^\n\n"
    }

summaryDiag :: SolcDiag
summaryDiag =
  SolcDiag
    { sd_code = "1391"
    , sd_severity = "info"
    , sd_message = "CHC: 1 verification condition(s) proved safe! Enable the model checker option \"show proved safe\" to see all of them."
    , sd_formatted = "Info: CHC: 1 verification condition(s) proved safe!\n\n"
    }

invariantDiag :: SolcDiag
invariantDiag =
  SolcDiag
    { sd_code = "1180"
    , sd_severity = "info"
    , sd_message = "Contract invariant(s) for Good.sol:Good:\n(true || true)"
    , sd_formatted = "Info: Contract invariant(s) for Good.sol:Good:\n(true || true)\n"
    }

nonChcWarning :: SolcDiag
nonChcWarning =
  SolcDiag
    { sd_code = "2072"
    , sd_severity = "warning"
    , sd_message = "Unused local variable."
    , sd_formatted = "Warning: Unused local variable.\n --> Good.sol:7:5:\n"
    }

spec_solCheckClassify :: Spec
spec_solCheckClassify = describe "solCheckClassify" $ do
  it "classifies a proven check" $ do
    solCheckClassify [provenDiag]
      `shouldBe` [ SolPropertyResult
                     { spr_target = "Assertion violation"
                     , spr_status = "proven"
                     , spr_at = "Good.sol:9:5"
                     , spr_counterexample = Nothing
                     }
                 ]
  it "classifies a definite violation with its counterexample" $ do
    case solCheckClassify [violatedDiag] of
      [p] -> do
        spr_target p `shouldBe` "Assertion violation"
        spr_status p `shouldBe` "violated"
        spr_at p `shouldBe` "Probe.sol:5:5"
        fmap (T.isInfixOf "x = 42") (spr_counterexample p) `shouldBe` Just True
      ps -> expectationFailure $ "expected one result, got " <> show ps
  it "classifies an unproved check as unknown" $ do
    case solCheckClassify [unknownDiag] of
      [p] -> do
        spr_status p `shouldBe` "unknown"
        spr_at p `shouldBe` "Hard.sol:6:7"
        spr_counterexample p `shouldBe` Nothing
      ps -> expectationFailure $ "expected one result, got " <> show ps
  it "drops summary, invariant, and non-CHC diagnostics" $ do
    solCheckClassify [summaryDiag, invariantDiag, nonChcWarning] `shouldBe` []
  it "sorts results by location for deterministic reports" $ do
    let rs = solCheckClassify [unknownDiag, provenDiag, violatedDiag]
    map spr_at rs `shouldBe` ["Good.sol:9:5", "Hard.sol:6:7", "Probe.sol:5:5"]

subBS :: String -> LB.ByteString -> Bool
subBS needle hay = needle `isInfixOf` LB.unpack hay

spec_solCheckLevels :: Spec
spec_solCheckLevels = describe "companion-check levels" $ do
  it "parses the three levels and rejects junk" $ do
    parseCompanionCheckLevel "require" `shouldBe` Just CCL_Require
    parseCompanionCheckLevel "warn" `shouldBe` Just CCL_Warn
    parseCompanionCheckLevel "off" `shouldBe` Just CCL_Off
    parseCompanionCheckLevel "strict" `shouldBe` Nothing
  it "builds a chc request with the pinned settings" $ do
    let s = encode $ solCheckRequest 1234 "vault.sol"
    s `shouldSatisfy` subBS "\"engine\":\"chc\""
    s `shouldSatisfy` subBS "\"timeout\":1234"
    s `shouldSatisfy` subBS "\"showUnproved\":true"
    s `shouldSatisfy` subBS "vault.sol"
  it "treats violated as fatal only under --sol or require" $ do
    let mkP st =
          SolPropertyResult
            { spr_target = "Assertion violation"
            , spr_status = st
            , spr_at = ""
            , spr_counterexample = Nothing
            }
    let m =
          SolModuleReport
            { smr_path = "v.sol"
            , smr_contract = "V"
            , smr_solcVersion = ""
            , smr_artifact = Nothing
            , smr_properties = [mkP "violated", mkP "proven", mkP "unknown", mkP "skipped"]
            , smr_srcAbs = "v.sol"
            }
    map spr_status (solCheckFatalProps CCL_Warn False m) `shouldBe` []
    map spr_status (solCheckFatalProps CCL_Warn True m) `shouldBe` ["violated"]
    map spr_status (solCheckFatalProps CCL_Require False m)
      `shouldBe` ["violated", "unknown", "skipped"]
    map spr_status (solCheckFatalProps CCL_Off False m) `shouldBe` []
