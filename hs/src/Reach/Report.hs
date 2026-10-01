-- Usage reporting. Upstream Reach posted a record of every compile and CLI
-- run to log.reach.sh, a service this fork neither runs nor controls, so
-- reporting is disabled: `startReport` keeps its interface (and
-- `--disable-reporting` stays accepted) but sends nothing anywhere.
module Reach.Report (Report, startReport) where

import Control.Exception

type Report = Either SomeException ()

startReport :: Maybe String -> String -> IO (Report -> IO ())
startReport _ _ = return $ \_ -> return ()
