module Main where

import Data.Text (pack)
import Products.Autopilot.K8s.Kubectl (K8sError (..), isIdempotentSuccess)

main :: IO ()
main = do
  if isIdempotentSuccess (K8sError (pack "AlreadyExists"))
    then putStrLn "tests-passed"
    else fail "idempotency test failed"
